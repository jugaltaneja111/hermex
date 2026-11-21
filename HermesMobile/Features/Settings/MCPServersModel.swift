import Foundation
import Observation

@MainActor
@Observable
final class MCPServersModel {
    enum State: Equatable {
        case loading
        case loaded
        case unsupported
        case failed(String)
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    private(set) var profile: String?
    private(set) var servers: [HermesMCPServer] = []
    private(set) var presets: [HermesMCPPreset] = []
    private(set) var busy: String?
    private(set) var tests: [String: HermesMCPTest] = [:]
    var actionError: String?

    private let client: HermesMCPClient
    @ObservationIgnored private var readSerial = 0

    init(client: HermesMCPClient, profile: String? = nil) {
        self.client = client
        self.profile = profile
    }

    func server(_ name: String) -> HermesMCPServer? { servers.first { $0.name == name } }

    func load() async {
        if state != .loaded { state = .loading }
        readSerial += 1
        let serial = readSerial
        do {
            let listed = try await client.profiles()
            guard serial == readSerial else { return }
            profiles = listed.names
            if profile.map(listed.names.contains) != true {
                profile = listed.initial
                reset()
            }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
            return
        }
        await loadServers()
    }

    func select(_ name: String) async {
        guard name != profile, busy == nil else { return }
        profile = name
        reset()
        await loadServers()
    }

    @discardableResult
    func add(_ preset: HermesMCPPreset, keys: [String: String] = [:]) async -> Bool {
        await act(on: preset.name) { try await self.client.add(preset, keys: keys, profile: $0) }
    }

    @discardableResult
    func add(name: String, url: URL, token: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await act(on: name) { try await self.client.add(name: name, url: url, token: token.isEmpty ? nil : token, profile: $0) }
    }

    @discardableResult
    func setKey(_ value: String, for server: HermesMCPServer) async -> Bool {
        await act(on: server.name) { try await self.client.setKey(value, for: server, profile: $0) }
    }

    func remove(_ server: HermesMCPServer) async {
        _ = await act(on: server.name) { try await self.client.remove(server, profile: $0) }
    }

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
