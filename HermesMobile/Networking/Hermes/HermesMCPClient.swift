import Foundation

struct HermesMCPServer: Identifiable, Equatable, Sendable {
    let name: String
    let transport: String
    let address: String?
    let isEnabled: Bool
    let plugin: String?
    let usesOAuth: Bool
    let hasOAuthTokens: Bool?

    var id: String { name }
    var isEditable: Bool { plugin == nil }
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

struct HermesMCPPreset: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    let requires: [String]

    var id: String { name }
}

struct HermesMCPTest: Equatable, Sendable {
    let isConnected: Bool
    let tools: Int
    let error: String?
    let needsSignIn: Bool

    init(_ reply: BotJSON) {
        isConnected = reply["ok"].flag == true
        tools = reply["tools"].list?.count ?? 0
        error = reply["error"].text.flatMap { $0.isEmpty ? nil : $0 }
        needsSignIn = reply["oauth_needed"].flag == true && reply["oauth_tokens_present"].flag != true
    }
}

struct HermesMCPUnsupported: Error, Equatable {}

@MainActor final class HermesMCPClient {
    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    func profiles() async throws -> (names: [String], initial: String) {
        try await HermesEnvironmentClient(http: http).profiles()
    }

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

    func add(_ preset: HermesMCPPreset, keys: [String: String], profile: String) async throws {
        try await gateway { client in
            _ = try await client.call(.mcpServersAdd(profile: profile, name: preset.name, preset: preset.name, url: nil, bearerToken: nil))
            for key in preset.requires {
                guard let value = keys[key], !value.isEmpty else { continue }
                _ = try await client.call(.mcpServersSetAPIKey(profile: profile, name: preset.name, value: value, envVar: key))
            }
        }
    }

    func add(name: String, url: URL, token: String?, profile: String) async throws {
        _ = try await gateway {
            try await $0.call(.mcpServersAdd(profile: profile, name: name, preset: nil, url: url, bearerToken: token))
        }
    }

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
