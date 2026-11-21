import XCTest
@testable import HermesMobile

@MainActor final class SkillsHubModelTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testBrowsingAddsEachLaterPageUnderTheFirst() async throws {
        let host = BotSocketHost()
        host.next("skills.manage", .init(result: page([item("pdf"), item("mail")], of: 2)))
        host.next("skills.manage", .init(result: page([item("mail"), item("calendar")], of: 2)))
        let model = model(on: host)

        await model.load()

        XCTAssertEqual(model.skills.map(\.name), ["pdf", "mail"])
        XCTAssertTrue(model.hasMore)

        await model.loadMore()

        XCTAssertEqual(model.skills.map(\.name), ["pdf", "mail", "calendar"], "a row the next page repeats is not listed twice")
        XCTAssertFalse(model.hasMore)
        let second = try XCTUnwrap(host.requests.last { $0["method"].text == "skills.manage" })["params"]
        XCTAssertEqual(second["action"].text, "browse"); XCTAssertEqual(second["page"].integer, 2)
        XCTAssertEqual(second["profile"].text, "dev")
    }

    func testASearchResultInstallsByItsNameAndABrowsedOneByItsIdentifier() async throws {
        let host = BotSocketHost()
        host.next("skills.manage", .init(result: .object(["results": .array([
            .object(["name": .string("pdf"), "description": .string("Reads PDFs")])
        ])])))
        host.always("skills.manage", .init(result: .object(["installed": .bool(true), "name": .string("pdf")])))
        let model = model(on: host)
        model.query = " pdf "

        await model.load()

        let search = try XCTUnwrap(host.requests.last { $0["method"].text == "skills.manage" })["params"]
        XCTAssertEqual(search["action"].text, "search"); XCTAssertEqual(search["query"].text, "pdf")
        let found = try XCTUnwrap(model.skills.first)

        let installed = await model.install(found)

        XCTAssertTrue(installed)
        XCTAssertTrue(model.installed.contains(found.id))
        let byName = try XCTUnwrap(host.requests.last { $0["method"].text == "skills.manage" })["params"]
        XCTAssertEqual(byName["action"].text, "install"); XCTAssertEqual(byName["query"].text, "pdf")
        XCTAssertEqual(byName["profile"].text, "dev")

        let browsed = try XCTUnwrap(HermesHubSkill(item("mail")))
        await model.install(browsed)

        let byIdentifier = try XCTUnwrap(host.requests.last { $0["method"].text == "skills.manage" })["params"]
        XCTAssertEqual(byIdentifier["query"].text, "hub/mail")
    }

    func testARefusedInstallIsReportedAndNotMarkedInstalled() async throws {
        let host = BotSocketHost()
        host.always("skills.manage", .init(error: 5031, message: "Blocked by the security scan"))
        let model = model(on: host)
        let skill = try XCTUnwrap(HermesHubSkill(item("pdf")))

        let installed = await model.install(skill)

        XCTAssertFalse(installed)
        XCTAssertNotNil(model.actionError)
        XCTAssertFalse(model.installed.contains(skill.id))
    }

    func testAHostWithoutTheHubSaysSo() async {
        let host = BotSocketHost()
        host.always("skills.manage", .init(error: -32601))
        let model = model(on: host)

        await model.load()

        XCTAssertEqual(model.state, .unsupported)
    }

    private func item(_ name: String) -> BotJSON {
        .object(["name": .string(name), "description": .string("What \(name) does"), "source": .string("github"),
                 "trust": .string("community"), "identifier": .string("hub/\(name)")])
    }

    private func page(_ items: [BotJSON], of total: Int) -> BotJSON {
        .object(["items": .array(items), "page": .number(1), "total_pages": .number(Double(total)), "total": .number(3)])
    }

    private func model(on host: BotSocketHost) -> SkillsHubModel {
        SkillsHubModel(client: HermesSkillsHubClient(http: host.connection(record), profile: "dev"))
    }
}
