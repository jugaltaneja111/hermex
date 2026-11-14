import Foundation

/// One MCP server in a Profile's config, as `mcp.servers.list` describes it. Secrets never
/// arrive: the host sends the names of the keys a server uses, not their values.
struct HermesMCPServer: Identifiable, Equatable, Sendable {
    let name: String
    let transport: String
    /// The server's web address, or the command the host runs for it.
    let address: String?
    let isEnabled: Bool
    /// The plugin that provides the server. Such a server is read-only: only the plugin changes it.
    let plugin: String?
    /// The server signs in with OAuth, which is finished on the host's own machine.
    let usesOAuth: Bool
    /// Whether that sign-in's tokens are on the host; nil when it is not an OAuth server.
    let hasOAuthTokens: Bool?

    var id: String { name }
    var isEditable: Bool { plugin == nil }
    /// A credential typed on the phone fits: an OAuth server takes a browser sign-in instead.
    var takesKey: Bool { isEditable && !usesOAuth }

    init?(_ row: BotJSON) {
        guard let name = row["name"].text, !name.isEmpty else { return nil }
        self.name = name
        transport = row["transport"].text ?? ""
        address = [row["url"].text, row["command"].text].compactMap { $0 }.first { !$0.isEmpty }
        isEnabled = row["enabled"].flag != false
        plugin = row["source"].text == "plugin" ? (row["plugin"].text ?? "") : nil
        usesOAuth = row["auth"].text == "oauth"
        hasOAuthTokens = row["oauth_tokens_present"].flag
    }
}

/// One of the host's ready-made MCP servers a Profile has not added yet.
struct HermesMCPPreset: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    /// The `.env` keys the server needs before it can connect, by name.
    let requires: [String]

    var id: String { name }
}

/// What testing a server came to: how many tools it listed, or why it didn't connect.
struct HermesMCPTest: Equatable, Sendable {
    let isConnected: Bool
    let tools: Int
    let error: String?
    /// The server needs an OAuth sign-in that has not been finished on the host.
    let needsSignIn: Bool

    init(_ reply: BotJSON) {
        isConnected = reply["ok"].flag == true
        tools = reply["tools"].list?.count ?? 0
        error = reply["error"].text.flatMap { $0.isEmpty ? nil : $0 }
        needsSignIn = reply["oauth_needed"].flag == true && reply["oauth_tokens_present"].flag != true
    }
}

/// A host with no `mcp.*` methods (-32601), which is older than the screen needs.
struct HermesMCPUnsupported: Error, Equatable {}

/// The MCP Servers screen's client on a Hermes host: the `mcp.catalog` and `mcp.servers.*` RPCs
/// for one Profile, over the sign-in and socket the server's Bot screens share. Every call names
/// the Profile and nothing is cached, so a server never shows under another host or Profile. A
/// key or token is sent once, in the call that saves it on the host, and never kept here.
@MainActor final class HermesMCPClient {
    private let http: HermesConnection

    /// `server`'s saved connection, on the sign-in and socket its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    /// The host's Profiles and the one to start on, its default.
    func profiles() async throws -> (names: [String], initial: String) {
        try await HermesEnvironmentClient(http: http).profiles()
    }

    /// `profile`'s servers by name, and the presets it has not added. A catalog the host can't
    /// read leaves the presets empty; the Profile's own servers still show.
    func servers(profile: String) async throws -> (added: [HermesMCPServer], presets: [HermesMCPPreset]) {
        try await gateway { client in
            let added = (try await client.call(.mcpServersList(profile: profile))["servers"].list ?? []).compactMap(HermesMCPServer.init)
            let catalog = (try? await client.call(.mcpCatalog(profile: profile)))?["servers"].list ?? []
            let taken = Set(added.map(\.name))
            let presets: [HermesMCPPreset] = catalog.compactMap { row in
                guard let name = row["name"].text, !name.isEmpty, row["installed"].flag != true, !taken.contains(name) else { return nil }
                return HermesMCPPreset(name: name, summary: row["description"].text ?? "",
                                       requires: (row["requires"].list ?? []).compactMap(\.text).filter { !$0.isEmpty })
            }
            return (added, presets)
        }
    }

    /// Adds `preset` under its own name, then saves each key it needs. A key the host refuses
    /// leaves the server added, without that key.
    func add(_ preset: HermesMCPPreset, keys: [String: String], profile: String) async throws {
        try await gateway { client in
            _ = try await client.call(.mcpServersAdd(profile: profile, name: preset.name, preset: preset.name, url: nil, bearerToken: nil))
            for key in preset.requires {
                guard let value = keys[key], !value.isEmpty else { continue }
                _ = try await client.call(.mcpServersSetAPIKey(profile: profile, name: preset.name, value: value, envVar: key))
            }
        }
    }

    /// Adds a server by its web address, with the bearer token it asks for when it has one.
    func add(name: String, url: URL, token: String?, profile: String) async throws {
        _ = try await gateway {
            try await $0.call(.mcpServersAdd(profile: profile, name: name, preset: nil, url: url, bearerToken: token))
        }
    }

    /// Saves `value` as `server`'s credential, under the host's default key name for it.
    func setKey(_ value: String, for server: HermesMCPServer, profile: String) async throws {
        _ = try await gateway {
            try await $0.call(.mcpServersSetAPIKey(profile: profile, name: server.name, value: value, envVar: nil))
        }
    }

    func test(_ server: HermesMCPServer, profile: String) async throws -> HermesMCPTest {
        HermesMCPTest(try await gateway { try await $0.call(.mcpServersTest(profile: profile, name: server.name)) })
    }

    func remove(_ server: HermesMCPServer, profile: String) async throws {
        _ = try await gateway { try await $0.call(.mcpServersRemove(profile: profile, name: server.name)) }
    }

    private func gateway<Value>(_ work: (BotClient) async throws -> Value) async throws -> Value {
        let client = BotClient(http: http)
        defer { client.close() }
        do {
            try await client.connect()
            return try await work(client)
        } catch BotFailure.rejected(-32601), BotSettingFailure.rejected(-32601, _) {
            throw HermesMCPUnsupported()
        }
    }
}
