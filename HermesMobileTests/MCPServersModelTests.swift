import XCTest
@testable import HermesMobile

/// The MCP Servers screen on a Hermes host: `MCPServersModel` and the real client over a scripted
/// socket, with the fields `mcp.catalog` and `mcp.servers.*` answer at the pin (3b421578).
@MainActor final class MCPServersModelTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testAddedServersAndTheRemainingPresetsAreListed() async {
        let model = model(on: host(servers: [server("github", url: "https://mcp.github.example"), server("files", plugin: "desk")],
                                   presets: ["github", "linear"]))

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.servers.map(\.name), ["github", "files"])
        XCTAssertEqual(model.presets.map(\.name), ["linear"], "a preset the Profile already has is not offered again")
        XCTAssertEqual(model.server("github")?.isEditable, true)
        XCTAssertEqual(model.server("files")?.isEditable, false, "a plugin's server is only the plugin's to change")
    }

    func testAHostWithoutMCPMethodsSaysSo() async {
        let host = BotSocketHost()
        host.always("profiles.list", .init(result: profiles))
        host.always("mcp.servers.list", .init(error: -32601))
        let model = model(on: host)

        await model.load()

        XCTAssertEqual(model.state, .unsupported)
    }

    func testAddingAPresetNamesTheShownProfileAndSavesItsKeys() async throws {
        let host = host(servers: [], presets: ["linear"], requires: ["LINEAR_API_KEY"])
        host.always("mcp.servers.add", .init(result: .object(["ok": .bool(true), "name": .string("linear")])))
        host.always("mcp.servers.set_api_key", .init(result: .object(["ok": .bool(true)])))
        let model = model(on: host)
        await model.load()
        await model.select("dev")
        let preset = try XCTUnwrap(model.presets.first)
        host.always("mcp.servers.list", .init(result: .object(["servers": .array([server("linear", url: "https://mcp.linear.example")])])))

        let added = await model.add(preset, keys: ["LINEAR_API_KEY": "lin_secret"])

        XCTAssertTrue(added)
        let add = try XCTUnwrap(host.requests.last { $0["method"].text == "mcp.servers.add" })["params"]
        XCTAssertEqual(add["profile"].text, "dev")
        XCTAssertEqual(add["name"].text, "linear"); XCTAssertEqual(add["preset"].text, "linear")
        let key = try XCTUnwrap(host.requests.last { $0["method"].text == "mcp.servers.set_api_key" })["params"]
        XCTAssertEqual(key["profile"].text, "dev"); XCTAssertEqual(key["name"].text, "linear")
        XCTAssertEqual(key["env_var"].text, "LINEAR_API_KEY"); XCTAssertEqual(key["value"].text, "lin_secret")
        XCTAssertEqual(model.servers.map(\.name), ["linear"], "the list is read again after the write")
    }

    func testACustomServerSendsItsAddressAndARefusalIsReported() async throws {
        let host = host(servers: [], presets: [])
        host.next("mcp.servers.add", .init(error: 4090, message: "server 'docs' already exists"))
        host.always("mcp.servers.add", .init(result: .object(["ok": .bool(true), "name": .string("docs")])))
        let model = model(on: host)
        await model.load()
        let url = try XCTUnwrap(URL(string: "https://mcp.docs.example/mcp"))

        let refused = await model.add(name: "docs", url: url, token: "")

        XCTAssertFalse(refused)
        XCTAssertNotNil(model.actionError, "the host's refusal reaches the screen")

        let added = await model.add(name: " docs ", url: url, token: "tok")

        XCTAssertTrue(added)
        let add = try XCTUnwrap(host.requests.last { $0["method"].text == "mcp.servers.add" })["params"]
        XCTAssertEqual(add["name"].text, "docs")
        XCTAssertEqual(add["config"]["url"].text, "https://mcp.docs.example/mcp")
        XCTAssertEqual(add["bearer_token"].text, "tok")
        XCTAssertEqual(add["preset"], .null)
    }

    func testATestKeepsWhatTheHostFoundAndRemovalNamesTheServer() async throws {
        let host = host(servers: [server("github", url: "https://mcp.github.example")], presets: [])
        host.always("mcp.servers.test", .init(result: .object(["ok": .bool(false), "error": .string("401"), "tools": .array([]),
                                                               "oauth_needed": .bool(true), "oauth_tokens_present": .bool(false)])))
        host.always("mcp.servers.remove", .init(result: .object(["ok": .bool(true), "removed": .bool(true)])))
        let model = model(on: host)
        await model.load()
        let github = try XCTUnwrap(model.server("github"))

        await model.test(github)

        XCTAssertEqual(model.tests["github"]?.isConnected, false)
        XCTAssertEqual(model.tests["github"]?.needsSignIn, true)

        host.always("mcp.servers.list", .init(result: .object(["servers": .array([])])))
        await model.remove(github)

        let remove = try XCTUnwrap(host.requests.last { $0["method"].text == "mcp.servers.remove" })["params"]
        XCTAssertEqual(remove["name"].text, "github"); XCTAssertEqual(remove["profile"].text, "default")
        XCTAssertNil(model.server("github"))
    }

    // MARK: - Helpers

    private var profiles: BotJSON {
        .object(["profiles": .array([
            .object(["name": .string("default"), "is_default": .bool(true)]), .object(["name": .string("dev")])
        ])])
    }

    private func host(servers: [BotJSON], presets: [String], requires: [String] = []) -> BotSocketHost {
        let host = BotSocketHost()
        host.always("profiles.list", .init(result: profiles))
        host.always("mcp.servers.list", .init(result: .object(["servers": .array(servers)])))
        host.always("mcp.catalog", .init(result: .object(["servers": .array(presets.map { name in
            .object(["name": .string(name), "description": .string("What \(name) does"), "installed": .bool(false),
                     "enabled": .bool(false), "requires": .array(requires.map(BotJSON.string)), "transport": .string("http")])
        })])))
        return host
    }

    private func server(_ name: String, url: String? = nil, plugin: String? = nil) -> BotJSON {
        .object(["name": .string(name), "transport": .string("http"), "url": url.map(BotJSON.string) ?? .null,
                 "args": .array([]), "env": .array([]), "enabled": .bool(true),
                 "source": .string(plugin == nil ? "config" : "plugin"), "plugin": plugin.map(BotJSON.string) ?? .null])
    }

    private func model(on host: BotSocketHost) -> MCPServersModel {
        MCPServersModel(client: HermesMCPClient(http: host.connection(record)))
    }
}
