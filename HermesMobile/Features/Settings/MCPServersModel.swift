import Foundation
import Observation

/// The MCP Servers screen's state: the host's Profiles, the one shown, the servers its config
/// has and the presets it could add. Every read goes to the host; nothing is kept past the screen.
@MainActor
@Observable
final class MCPServersModel {
    enum State: Equatable {
        case loading
        case loaded
        /// The host has no MCP server methods: it is older than this screen needs.
        case unsupported
        case failed(String)
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    /// The Profile the screen lists and writes to, once the host has named its Profiles.
    private(set) var profile: String?
    private(set) var servers: [HermesMCPServer] = []
    private(set) var presets: [HermesMCPPreset] = []
    /// The server or preset whose write or test is in flight. One at a time: each write ends in a
    /// fresh read, and a second one started meanwhile would act on rows about to change.
    private(set) var busy: String?
    /// Each server's last test on this screen, by name. Dropped with the Profile.
    private(set) var tests: [String: HermesMCPTest] = [:]
    /// The last action's refusal, for the screen's alert.
    var actionError: String?

    private let client: HermesMCPClient
    /// Bumped by each read, so only the latest one applies after a Profile switch.
    @ObservationIgnored private var readSerial = 0

    /// `profile` is shown first while the host still lists it.
    init(client: HermesMCPClient, profile: String? = nil) {
        self.client = client
        self.profile = profile
    }

    func server(_ name: String) -> HermesMCPServer? { servers.first { $0.name == name } }

    /// Reads the host's Profiles, keeping the shown one while it still exists and otherwise
    /// starting on the default, then that Profile's servers.
    func load() async {
        if state != .loaded { state = .loading }
        readSerial += 1
        let serial = readSerial
        do {
            let listed = try await client.profiles()
            guard serial == readSerial else { return }
            profiles = listed.names
            if profile.map(listed.names.contains) != true {
                // The shown Profile is gone: its servers must not stay tappable under the new one.
                profile = listed.initial
                reset()
            }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
            return
        }
        await loadServers()
    }

    /// Shows another Profile's servers. Not while a write is in flight: its result would land
    /// under a Profile it was not started for.
    func select(_ name: String) async {
        guard name != profile, busy == nil else { return }
        profile = name
        reset()
        await loadServers()
    }

    /// Adds a preset with the keys typed for it. True when the host took it.
    @discardableResult
    func add(_ preset: HermesMCPPreset, keys: [String: String] = [:]) async -> Bool {
        await act(on: preset.name) { try await self.client.add(preset, keys: keys, profile: $0) }
    }

    /// Adds a server by web address. True when the host took it.
    @discardableResult
    func add(name: String, url: URL, token: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await act(on: name) { try await self.client.add(name: name, url: url, token: token.isEmpty ? nil : token, profile: $0) }
    }

    /// Saves a credential for `server`. True when the host took it.
    @discardableResult
    func setKey(_ value: String, for server: HermesMCPServer) async -> Bool {
        await act(on: server.name) { try await self.client.setKey(value, for: server, profile: $0) }
    }

    /// Removes `server` from the Profile's config. Its saved key stays in the host's `.env`.
    func remove(_ server: HermesMCPServer) async {
        _ = await act(on: server.name) { try await self.client.remove(server, profile: $0) }
    }

    /// Asks the host to connect to `server` once and keeps what it found. Nothing is re-read:
    /// a test changes nothing on the host.
    func test(_ server: HermesMCPServer) async {
        guard let profile, busy == nil else { return }
        busy = server.name
        defer { busy = nil }
        do {
            let result = try await client.test(server, profile: profile)
            if self.profile == profile { tests[server.name] = result }
        } catch {
            if self.profile == profile, !Task.isCancelled { actionError = Self.message(for: error) }
        }
    }

    private func reset() {
        state = .loading
        servers = []; presets = []; tests = [:]
    }

    /// Runs one write on the shown Profile and reads the list again, whether it worked or not:
    /// the host's rows are the only truth about what changed.
    private func act(on name: String, _ work: (String) async throws -> Void) async -> Bool {
        guard let profile, busy == nil else { return false }
        busy = name
        defer { busy = nil }
        var worked = true
        do {
            try await work(profile)
        } catch {
            worked = false
            if self.profile == profile, !Task.isCancelled { actionError = Self.message(for: error) }
        }
        tests[name] = nil
        if self.profile == profile { await loadServers() }
        return worked
    }

    private func loadServers() async {
        guard let profile else { return }
        readSerial += 1
        let serial = readSerial
        do {
            let listed = try await client.servers(profile: profile)
            guard serial == readSerial else { return }
            servers = listed.added; presets = listed.presets
            state = .loaded
        } catch is HermesMCPUnsupported {
            if serial == readSerial { state = .unsupported }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }

    private static func message(for error: Error) -> String {
        error is HermesMCPUnsupported
            ? String(localized: "MCP servers need a newer Hermes release. Update Hermes on your server, then refresh.")
            : error.localizedDescription
    }
}
