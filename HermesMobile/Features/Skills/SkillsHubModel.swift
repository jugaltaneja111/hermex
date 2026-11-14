import Foundation
import Observation

/// The skills hub screen's state for one Profile: the hub's pages or one search's results, and
/// the install in flight. Nothing is kept past the screen.
@MainActor
@Observable
final class SkillsHubModel {
    enum State: Equatable {
        case loading
        case loaded
        /// The host has no skills hub: it is older than this screen needs.
        case unsupported
        case failed(String)
    }

    private(set) var state = State.loading
    private(set) var skills: [HermesHubSkill] = []
    /// A later page of the hub exists. Never true for search results, which come whole.
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// The skill being installed. One at a time.
    private(set) var installing: String?
    /// The skills this screen installed, by id, so their rows say so.
    private(set) var installed: Set<String> = []
    /// The last install's refusal, in the host's words, for the screen's alert.
    var actionError: String?
    var query = ""

    var profile: String { client.profile }

    private let client: HermesSkillsHubClient
    private var page = 1
    /// Bumped by each list read, so a slow page never lands on a newer search.
    @ObservationIgnored private var readSerial = 0

    init(client: HermesSkillsHubClient) { self.client = client }

    /// The hub's first page, or the search's results while there is search text.
    func load() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        readSerial += 1
        let serial = readSerial
        state = .loading
        do {
            if needle.isEmpty {
                let first = try await client.browse(page: 1)
                guard serial == readSerial else { return }
                skills = first.skills; hasMore = first.hasMore; page = 1
            } else {
                let found = try await client.search(needle)
                guard serial == readSerial else { return }
                skills = found; hasMore = false
            }
            state = .loaded
        } catch is HermesSkillsHubUnsupported {
            if serial == readSerial { state = .unsupported }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }

    /// The hub's next page, added under the rows shown. A failure keeps what is shown.
    func loadMore() async {
        guard hasMore, !isLoadingMore, state == .loaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let serial = readSerial
        guard let next = try? await client.browse(page: page + 1), serial == readSerial else { return }
        let shown = Set(skills.map(\.id))
        skills += next.skills.filter { !shown.contains($0.id) }
        hasMore = next.hasMore; page += 1
    }

    func info(for skill: HermesHubSkill) async -> HermesHubSkillInfo? {
        try? await client.inspect(skill)
    }

    /// Installs `skill` into the Profile. True once the host says it is installed; a lost reply
    /// is reported and never sent again.
    @discardableResult
    func install(_ skill: HermesHubSkill) async -> Bool {
        guard installing == nil else { return false }
        installing = skill.id
        defer { installing = nil }
        do {
            try await client.install(skill)
            installed.insert(skill.id)
            return true
        } catch {
            if !Task.isCancelled {
                actionError = error is HermesSkillsHubUnsupported
                    ? String(localized: "Installing skills needs a newer Hermes release. Update Hermes on your server, then try again.")
                    : error.localizedDescription
            }
            return false
        }
    }
}
