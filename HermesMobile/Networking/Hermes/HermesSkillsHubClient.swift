import Foundation

struct HermesHubSkill: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let source: String?
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

struct HermesHubSkillInfo: Equatable, Sendable {
    let summary: String?
    let source: String?
    let tags: [String]
    let preview: String?

    init?(_ info: BotJSON) {
        guard info.fields?.isEmpty == false else { return nil }
        summary = info["description"].text
        source = info["source"].text
        tags = (info["tags"].list ?? []).compactMap(\.text)
        preview = info["skill_md_preview"].text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct HermesSkillsHubUnsupported: Error, Equatable {}

@MainActor final class HermesSkillsHubClient {
    let profile: String
    private let http: HermesConnection

    init(http: HermesConnection, profile: String) {
        self.http = http
        self.profile = profile
    }

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
