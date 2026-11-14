import Foundation

/// One skill the hub offers. `id` is what an install names it by: the hub's identifier from a
/// browse, or the name from a search, whose rows carry none and which the host then resolves.
struct HermesHubSkill: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    /// Where the skill comes from, such as a repository, when the hub says.
    let source: String?
    /// The hub's trust label for that source, as the host words it.
    let trust: String?

    init?(_ row: BotJSON) {
        guard let name = row["name"].text, !name.isEmpty else { return nil }
        self.name = name
        id = row["identifier"].text.flatMap { $0.isEmpty ? nil : $0 } ?? name
        summary = row["description"].text ?? ""
        source = row["source"].text.flatMap { $0.isEmpty ? nil : $0 }
        trust = row["trust"].text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// What the hub knows about one skill before it is installed.
struct HermesHubSkillInfo: Equatable, Sendable {
    let summary: String?
    let source: String?
    let tags: [String]
    /// The start of its SKILL.md, the instructions the agent would follow.
    let preview: String?

    /// Nil for the host's `{}`, an identifier the hub resolves nowhere.
    init?(_ info: BotJSON) {
        guard info.fields?.isEmpty == false else { return nil }
        summary = info["description"].text
        source = info["source"].text
        tags = (info["tags"].list ?? []).compactMap(\.text)
        preview = info["skill_md_preview"].text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A host with no skills hub (-32601, or 4017 for a `skills.manage` without these actions).
struct HermesSkillsHubUnsupported: Error, Equatable {}

/// The skills hub for one Profile on a Hermes host: `skills.manage`'s browse, search, inspect and
/// install, over the sign-in and socket the server's Bot screens share. Reads go to the hub the
/// host is set up with; an install writes that Profile's skills folder and nowhere else.
@MainActor final class HermesSkillsHubClient {
    let profile: String
    private let http: HermesConnection

    init(http: HermesConnection, profile: String) {
        self.http = http
        self.profile = profile
    }

    /// One page of the hub, from 1, and whether a later page exists.
    func browse(page: Int) async throws -> (skills: [HermesHubSkill], hasMore: Bool) {
        let reply = try await gateway { try await $0.call(.skillsHubBrowse(profile: self.profile, page: page)) }
        let skills = (reply["items"].list ?? []).compactMap(HermesHubSkill.init)
        return (skills, !skills.isEmpty && page < (reply["total_pages"].integer ?? page))
    }

    func search(_ query: String) async throws -> [HermesHubSkill] {
        let reply = try await gateway { try await $0.call(.skillsHubSearch(profile: self.profile, query: query)) }
        return (reply["results"].list ?? []).compactMap(HermesHubSkill.init)
    }

    func inspect(_ skill: HermesHubSkill) async throws -> HermesHubSkillInfo? {
        let reply = try await gateway { try await $0.call(.skillsHubInspect(profile: self.profile, identifier: skill.id)) }
        return HermesHubSkillInfo(reply["info"])
    }

    /// Installs `skill` into the Profile. A refusal carries the host's reason, such as a failed
    /// security scan; a reply that does not say `installed` is not a success.
    func install(_ skill: HermesHubSkill) async throws {
        let reply = try await gateway { try await $0.call(.skillsHubInstall(profile: self.profile, identifier: skill.id)) }
        guard reply["installed"].flag == true else { throw BotFailure.unsupported }
    }

    private func gateway(_ work: (BotClient) async throws -> BotJSON) async throws -> BotJSON {
        let client = BotClient(http: http)
        defer { client.close() }
        do {
            try await client.connect()
            return try await work(client)
        } catch BotFailure.rejected(-32601), BotFailure.rejected(4017), BotSettingFailure.rejected(-32601, _),
                BotSettingFailure.rejected(4017, _) {
            throw HermesSkillsHubUnsupported()
        }
    }
}
