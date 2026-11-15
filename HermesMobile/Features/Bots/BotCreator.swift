import Foundation
import Observation

/// Hermes Profile names as the host validates them: `[a-z0-9][a-z0-9_-]{0,63}`,
/// never `default` or another reserved word. The slug is derived from the display
/// name the user types, so the roster title and the folder name stay related.
enum BotProfileName {
    static let reserved: Set<String> = ["hermes", "default", "test", "tmp", "root", "sudo"]

    static func slug(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" {
                if pendingDash, !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else { pendingDash = true }
        }
        return String(result.prefix(64))
    }

    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64, !reserved.contains(name) else { return false }
        guard ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }
}

/// One bot creation or duplication for one connection. Setup is three host writes
/// in order: the Profile (`profiles.create`), its look (`profiles.configure`) and
/// its canonical "Bot Chat" (`session.create` + `session.title`). A copy, either a
/// duplicate or a new bot that copies another bot's setup, is a `clone_from`: the host
/// copies config, keys, plugins, skills and MCP servers. When the sheet turned some of
/// them off, a capabilities step (`profiles.configure`, `plugins.manage toggle`) turns
/// them off in the copy, and when it chose not to copy memory, a memory step deletes
/// the copied memory files.
/// Each step records
/// its own outcome; Try Again repeats only the steps that are not done, and a
/// step whose reply was lost re-reads the host before writing again, so a retry
/// never mints a second Profile or a second chat.
@MainActor @Observable final class BotCreator {
    enum Step: CaseIterable, Identifiable {
        case profile, capabilities, memory, look, chat
        var id: Self { self }
        var title: String {
            switch self {
            case .profile: return String(localized: "Profile")
            case .capabilities: return String(localized: "Capabilities")
            case .memory: return String(localized: "Memory")
            case .look: return String(localized: "Look")
            case .chat: return String(localized: "Bot Chat")
            }
        }
    }
    enum Outcome: Equatable { case done, failed(String), uncertain }
    enum Phase: Equatable { case editing, creating, created }
    /// The source bot's lists a copy can switch rows of.
    enum Capability: String, Identifiable, CaseIterable {
        case skills, toolsets, plugins, mcpServers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .skills: return String(localized: "Skills")
            case .toolsets: return String(localized: "Toolsets")
            case .plugins: return String(localized: "Plugins")
            case .mcpServers: return String(localized: "MCP servers")
            }
        }
    }

    struct Draft: Equatable {
        var title = ""
        var role = ""
        var appearance = BotProfileAppearance(look: [:], fallbackTitle: "")
        var model: ModelCatalogOption?
        /// On: `share_auth`, the new bot reads the host's saved sign-ins and keys in
        /// place. Off: `mirror_credentials: false`, the bot starts with none. Values
        /// never travel to the phone either way.
        var sharesCredentials = true
        /// New bots only: becomes the Profile's `SOUL.md` when it has text. Empty keeps
        /// the host's default, or the instructions of the bot whose setup is copied.
        /// A duplicate copies the source's instead.
        var instructions = ""
        /// New bots that copy no setup only: `no_skills`, so the host seeds only its
        /// essential skills. The host refuses it with `clone_from`, since a copy brings
        /// the source's skills.
        var skipsBundledSkills = false
        /// Copies only: the source's skills, toolsets, enabled plugins and MCP servers as
        /// the copy should have them. Empty until the source has been read.
        var skills: [BotProfileCapability] = []
        var toolsets: [BotProfileCapability] = []
        var plugins: [BotProfileCapability] = []
        var mcpServers: [BotProfileCapability] = []
        /// Copies only: off deletes the copied memory files after the clone. A duplicate
        /// keeps them by default; a new bot that copies a setup starts without them.
        var keepsMemory = true
    }

    let server: URL
    let connection: BotConnection
    /// The bot being copied: the one duplicated, or the one whose setup a new bot copies.
    /// The host clones its config, keys, plugins and skills, and for a duplicate its
    /// instructions.
    private(set) var source: BotProfile?
    /// True for Duplicate. A new bot can still copy a setup, which sets `source`.
    let isDuplicate: Bool
    /// The bots a new bot can copy the setup of.
    let setupSources: [BotProfile]
    private(set) var draft: Draft
    private(set) var phase = Phase.editing
    /// True while the socket and model inventory are being opened; Create waits for it.
    private(set) var isLoading = false
    private(set) var outcomes: [Step: Outcome] = [:]
    private(set) var modelGroups: [ModelCatalogGroup] = []
    /// One-line note after a successful create when the host reports the bot
    /// ended up without a model, so the user knows to finish setup.
    private(set) var note: String?

    /// The source's lists as they were read, which is what a clone starts with.
    private var sourceLists: SourceLists?
    private let resetMemory: @MainActor (String) async throws -> Void
    private var taken: Set<String>
    private var wire: (any BotTransport)?
    private var generation = 0
    private let store: BotConnectionStore
    private let makeWire: @MainActor (BotConnection) -> any BotTransport
    private let onCreated: (String) -> Void

    init(server: URL, connection: BotConnection, roster: [BotProfile], source: BotProfile? = nil,
         store: BotConnectionStore? = nil, makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         resetMemory: (@MainActor (String) async throws -> Void)? = nil,
         onCreated: @escaping (String) -> Void = { _ in }) {
        self.server = server; self.connection = connection; self.source = source
        isDuplicate = source != nil
        setupSources = roster
        self.store = store ?? BotConnectionStore()
        self.makeWire = makeWire ?? { BotClient(saved: $0, server: server) }; self.onCreated = onCreated
        self.resetMemory = resetMemory ?? { profile in
            let reply = try await HermesConnections.shared.connection(for: connection, server: server).reply(.memoryReset(profile: profile))
            guard (200..<300).contains(reply.status) else { throw BotFailure.unsupported }
        }
        taken = Set(roster.map(\.id))
        var draft = Draft()
        if let source {
            draft.title = String(localized: "\(source.name) copy")
            draft.role = source.description ?? ""
            draft.appearance = BotProfileAppearance(profile: source)
            draft.appearance.imageKind = "shape"
        } else {
            draft.appearance.shape = BotAvatarShape.circle.rawValue
            draft.appearance.color = "#38bdf8"
            draft.appearance.custom = true
            draft.appearance.imageKind = "shape"
        }
        self.draft = draft
    }

    /// The Profile folder name the host will get; empty when the title yields none.
    var name: String { BotProfileName.slug(from: draft.title) }
    var nameIsTaken: Bool { taken.contains(name) }
    /// True once a create attempt has written anything: the name is committed and
    /// Try Again resumes the same bot instead of starting another.
    var hasStarted: Bool { !outcomes.isEmpty }
    var nameProblem: String? {
        let name = self.name
        if hasStarted || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if name.isEmpty || !BotProfileName.isValid(name) {
            return String(localized: "Use letters or numbers; “\(name.isEmpty ? draft.title : name)” is not allowed as a Profile name.")
        }
        if nameIsTaken { return String(localized: "A bot named “\(name)” already exists on this Hermes.") }
        return nil
    }
    var canCreate: Bool {
        phase == .editing && !isLoading && BotProfileName.isValid(name) && (hasStarted || !nameIsTaken)
    }
    /// The steps this create runs: the capabilities write only when the sheet changed a
    /// row, and the memory step only when a copy should not keep the source's memory.
    var steps: [Step] {
        let changed = sourceLists.map { $0 != SourceLists(draft) } ?? false
        let clearsMemory = source != nil && !draft.keepsMemory
        return Step.allCases.filter { ($0 != .capabilities || changed) && ($0 != .memory || clearsMemory) }
    }
    /// True after a create that finished with something left to do: a look that
    /// did not save or a bot with no model. The sheet stays up to say so.
    var needsAttention: Bool { note != nil || outcomes.values.contains { $0 != .done } }

    func setTitle(_ value: String) { draft.title = value; draft.appearance.title = value }
    func setRole(_ value: String) { draft.role = value }
    func setModel(_ value: ModelCatalogOption?) { draft.model = value }
    func setSharesCredentials(_ value: Bool) { draft.sharesCredentials = value }
    func setInstructions(_ value: String) { draft.instructions = value }
    func setSkipsBundledSkills(_ value: Bool) { draft.skipsBundledSkills = value }
    func setKeepsMemory(_ value: Bool) { draft.keepsMemory = value }
    func setEnabled(_ enabled: Bool, _ capability: Capability, id: String) {
        switch capability {
        case .skills: Self.set(enabled, id: id, in: &draft.skills)
        case .toolsets: Self.set(enabled, id: id, in: &draft.toolsets)
        case .plugins: Self.set(enabled, id: id, in: &draft.plugins)
        case .mcpServers: Self.set(enabled, id: id, in: &draft.mcpServers)
        }
    }
    func items(_ capability: Capability) -> [BotProfileCapability] {
        switch capability {
        case .skills: return draft.skills
        case .toolsets: return draft.toolsets
        case .plugins: return draft.plugins
        case .mcpServers: return draft.mcpServers
        }
    }
    private static func set(_ enabled: Bool, id: String, in rows: inout [BotProfileCapability]) {
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].enabled = enabled }
    }

    /// New bots only, before anything is written: copy `profile`'s setup, or nil for a
    /// fresh bot. Its lists are read again, and its memory is not copied unless asked.
    func setSetupSource(_ profile: BotProfile?) async {
        guard !isDuplicate, !hasStarted, phase == .editing, profile?.id != source?.id else { return }
        source = profile
        sourceLists = nil
        draft.skills = []; draft.toolsets = []; draft.plugins = []; draft.mcpServers = []
        draft.keepsMemory = false
        guard let client = wire else { return }
        await readSource(client, owner: generation)
    }
    func setShape(_ shape: BotAvatarShape) {
        draft.appearance.shape = shape.rawValue; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
        draft.appearance.generated = nil
    }
    func setGenerated(_ generated: BotGeneratedAvatar) {
        if draft.appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) == nil { draft.appearance.shape = BotAvatarShape.circle.rawValue }
        draft.appearance.generated = generated; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
    }
    var holdsConnection: Bool { wire != nil }

    /// "Describe It" under the default Profile: the new bot does not exist yet.
    func sendAvatarPrompt(_ prompt: String) async throws -> String {
        guard let client = wire else { throw BotFailure.stale }
        return try await BotAvatarGeneration.ask(prompt, profile: "default", transport: client, validateDispatch: validate(generation))
    }
    func setColor(_ hex: String) {
        if draft.appearance.shape.flatMap(BotAvatarShape.init(rawValue:)) == nil { draft.appearance.shape = BotAvatarShape.circle.rawValue }
        draft.appearance.color = hex; draft.appearance.custom = true; draft.appearance.imageKind = "shape"
    }
    func setExpression(_ expression: BotAvatarExpression) {
        draft.appearance.expression = expression == .neutral ? nil : expression.rawValue
    }

    /// Opens the socket and reads the model inventory and, for a duplicate, the source's
    /// skills and MCP servers. A failure here leaves that picker empty, and a duplicate
    /// then copies everything; the create itself reconnects if needed.
    func load() async {
        generation += 1
        let owner = generation
        wire?.close()
        let client = makeWire(connection)
        wire = client
        isLoading = true
        defer { if generation == owner { isLoading = false } }
        watchDisconnect(client, owner: owner)
        do {
            try ensureCurrentConnection()
            try await client.connect()
            try ensureOwner(owner, client)
            if let options = try? await client.call(.configuredModelOptions, validateDispatch: validate(owner)) {
                try ensureOwner(owner, client)
                modelGroups = HermesModelCatalog(options).groups
            }
            // Read once: a later load must not undo what the sheet already switched.
            if sourceLists == nil, !hasStarted { await readSource(client, owner: owner) }
        } catch {
            guard generation == owner, wire === client else { return }
            client.close(); wire = nil
        }
    }

    /// Reads the source's lists, which the sheet then switches rows of. A list that can't
    /// be read stays empty, and the copy keeps all of it. Plugins list only those the
    /// source has on, since only those can be turned off in the copy.
    private func readSource(_ client: any BotTransport, owner: Int) async {
        guard let source else { return }
        let profile = source.id
        var lists = SourceLists()
        if let payload = try? await client.call(.profilesDescribe(name: profile), validateDispatch: validate(owner)) {
            let details = BotProfileDetails(payload, expectedName: profile)
            lists.skills = details.skills; lists.toolsets = details.toolsets; lists.mcpServers = details.mcpServers
        }
        if let payload = try? await client.call(.pluginsList(profile: profile), validateDispatch: validate(owner)) {
            lists.plugins = (payload["plugins"].list ?? []).compactMap(HermesPlugin.init).filter(\.isEnabled).map {
                BotProfileCapability(id: $0.key, name: $0.name, detail: $0.summary.isEmpty ? nil : $0.summary, enabled: true)
            }
        }
        // The sheet may have moved on to another source, or closed, while this read.
        guard generation == owner, self.source?.id == profile, !hasStarted else { return }
        sourceLists = lists
        draft.skills = lists.skills; draft.toolsets = lists.toolsets
        draft.plugins = lists.plugins; draft.mcpServers = lists.mcpServers
    }

    func close() {
        generation += 1
        wire?.close(); wire = nil
        isLoading = false
        if phase == .creating {
            phase = .editing
            for step in steps where outcomes[step] == nil { outcomes[step] = .uncertain }
        }
    }

    /// Runs the steps that are not done yet. Never called twice concurrently.
    func create() async {
        guard canCreate else { return }
        generation += 1
        let owner = generation
        phase = .creating; note = nil
        outcomes = outcomes.filter { $0.value == .done || $0.value == .uncertain }
        let needsConnect = wire == nil
        let client = wire ?? makeWire(connection)
        wire = client
        watchDisconnect(client, owner: owner)
        do {
            try ensureCurrentConnection()
            if needsConnect {
                try await client.connect()
                try ensureOwner(owner, client)
            }
            try await createProfile(client, owner: owner)
            await configureCapabilities(client, owner: owner)
            await clearMemory(owner: owner)
            await configureLook(client, owner: owner)
            try await ensureChat(client, owner: owner)
            guard generation == owner else { return }
            phase = .created
            onCreated(name)
        } catch {
            // A disconnect clears `wire` before the suspended call throws, so only the
            // generation decides whether this attempt still owns the sheet.
            guard generation == owner else { return }
            if !(error is BotCreatorStop), let step = steps.first(where: { outcomes[$0] == nil }) {
                // A dropped connection mid-write leaves that write's fate unknown; the
                // next attempt re-reads the host before writing again.
                outcomes[step] = error as? BotFailure == .transport ? .uncertain : .failed(error.localizedDescription)
            }
            phase = .editing
            client.close(); wire = nil
        }
    }

    private func createProfile(_ client: any BotTransport, owner: Int) async throws {
        if outcomes[.profile] == .done { return }
        if outcomes[.profile] == .uncertain {
            let roster = try await client.call(.profilesList(includeSessions: false), validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            guard let rows = roster["profiles"].list else { throw BotFailure.unsupported }
            if rows.contains(where: { $0["name"].text == name }) { outcomes[.profile] = .done; return }
        }
        var profile = HermesCall.NewProfile(name: name, sharesCredentials: draft.sharesCredentials)
        let role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { profile.description = role }
        let instructions = draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source { profile.cloneFrom = source.id }
        // A new bot that copies a setup still gets its own instructions; a duplicate keeps the source's.
        if !isDuplicate, !instructions.isEmpty { profile.soul = draft.instructions }
        if source == nil { profile.skipsBundledSkills = draft.skipsBundledSkills }
        if let model = draft.model, let provider = model.providerID {
            profile.model = HermesCall.Model(id: model.id, provider: provider)
        }
        do {
            let reply = try await client.call(.profilesCreate(profile), validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            guard reply["ok"].flag == true else { throw BotFailure.unsupported }
            outcomes[.profile] = .done
            taken.insert(name)
            // A copy without a picked model keeps the source's, which the host reports as neither.
            let keepsSourceModel = source != nil && profile.model == nil
            if !keepsSourceModel, reply["model_set"].flag != true, reply["mirrored"]["model_inherited"].flag != true {
                note = String(localized: "No model is set for this bot yet. Pick one in Edit or in Hermes Desktop before chatting.")
            }
        } catch BotFailure.rejected(4062) {
            outcomes[.profile] = .failed(String(localized: "Hermes refused this name. It may already exist on the host."))
            throw BotCreatorStop()
        }
    }

    /// Turns off, in the copy, what the sheet turned off. The lists are whole, so a retry
    /// after a lost reply just sends them again. A failure is reported and fixable in the
    /// editor, and does not stop the chat step.
    private func configureCapabilities(_ client: any BotTransport, owner: Int) async {
        guard steps.contains(.capabilities), outcomes[.capabilities] != .done, let original = sourceLists else { return }
        var changes = HermesCall.ProfileChanges(name: name)
        if draft.skills != original.skills { changes.disabledSkills = draft.skills.filter { !$0.enabled }.map(\.id) }
        if draft.toolsets != original.toolsets { changes.enabledToolsets = draft.toolsets.filter(\.enabled).map(\.id) }
        if draft.mcpServers != original.mcpServers { changes.enabledMCPServers = draft.mcpServers.filter(\.enabled).map(\.id) }
        let failure = String(localized: "Some capabilities were not turned off. Edit the bot to set them.")
        do {
            var saved = true
            if changes != HermesCall.ProfileChanges(name: name) {
                let reply = try await client.call(.profilesConfigure(changes), validateDispatch: validate(owner))
                try ensureOwner(owner, client)
                saved = (changes.disabledSkills == nil || reply["applied"]["skills"].flag == true)
                    && (changes.enabledToolsets == nil || reply["applied"]["toolsets"].flag == true)
                    && (changes.enabledMCPServers == nil || reply["applied"]["mcp_servers"].flag == true)
            }
            // Turning a plugin off twice is harmless, so a retry sends every one again.
            for plugin in draft.plugins where !plugin.enabled {
                _ = try await client.call(.pluginsToggle(profile: name, key: plugin.id, enable: false), validateDispatch: validate(owner))
                try ensureOwner(owner, client)
            }
            outcomes[.capabilities] = saved ? .done : .failed(failure)
        } catch {
            guard generation == owner else { return }
            outcomes[.capabilities] = .failed(failure)
        }
    }

    /// Deletes the memory files the clone copied. Deleting again is harmless, so a retry
    /// just sends it again. A failure is reported and does not stop the chat step.
    private func clearMemory(owner: Int) async {
        guard steps.contains(.memory), outcomes[.memory] != .done else { return }
        do {
            try await resetMemory(name)
            guard generation == owner else { return }
            outcomes[.memory] = .done
        } catch {
            guard generation == owner else { return }
            outcomes[.memory] = .failed(String(localized: "The copied memory was not cleared."))
        }
    }

    /// The look is cosmetic: a failure is reported but does not stop the chat step.
    private func configureLook(_ client: any BotTransport, owner: Int) async {
        if outcomes[.look] == .done { return }
        var look = draft.appearance
        look.title = draft.title
        do {
            let reply = try await client.call(.profilesConfigure(.init(name: name, look: .init(fields: look.merging(into: [:]), revision: 0))),
                                              validateDispatch: validate(owner))
            try ensureOwner(owner, client)
            outcomes[.look] = reply["applied"]["ui_meta"].flag == true
                ? .done : .failed(String(localized: "The look was not saved. Edit the bot to set it."))
        } catch {
            guard generation == owner else { return }
            outcomes[.look] = .failed(String(localized: "The look was not saved. Edit the bot to set it."))
        }
    }

    /// Adopt-before-mint, as Desktop: an existing "Bot Chat" row is the bot's chat
    /// and is never duplicated. Only a confirmed absence creates one.
    private func ensureChat(_ client: any BotTransport, owner: Int) async throws {
        if outcomes[.chat] == .done { return }
        if try await findChat(client, owner: owner) { outcomes[.chat] = .done; return }
        await client.keepPlatformNote(profile: name)
        let created = try await client.call(.sessionCreate(profile: name), validateDispatch: validate(owner))
        try ensureOwner(owner, client)
        guard let runtime = created["session_id"].text, !runtime.isEmpty else { throw BotFailure.unsupported }
        // A canonical create already titled and hid it (#1603), and has no `session.title`.
        if client.speaksCanonicalProtocol { outcomes[.chat] = .done; return }
        do {
            // The created row is lazy; the title write persists it so the roster and
            // the phone's exact-title lookup find it before any prompt.
            _ = try await client.call(.sessionTitle(sessionID: runtime), validateDispatch: validate(owner))
            try ensureOwner(owner, client)
        } catch BotFailure.rejected(4022) {
            // Another writer took the title in between; that chat is the bot's.
            try ensureOwner(owner, client)
            guard try await findChat(client, owner: owner) else { throw BotFailure.unsupported }
        }
        outcomes[.chat] = .done
    }

    private func findChat(_ client: any BotTransport, owner: Int) async throws -> Bool {
        let lookup = try await client.call(.sessionList(profile: name), validateDispatch: validate(owner))
        try ensureOwner(owner, client)
        guard let rows = lookup["sessions"].list else { throw BotFailure.unsupported }
        return !rows.isEmpty
    }

    private func validate(_ owner: Int) -> () throws -> Void { { [weak self] in
        guard let self, self.generation == owner else { throw BotFailure.stale }
        try self.ensureCurrentConnection()
    } }

    private func ensureOwner(_ owner: Int, _ client: any BotTransport) throws {
        guard generation == owner, wire === client, !Task.isCancelled else { throw BotFailure.stale }
        try ensureCurrentConnection()
    }

    private func ensureCurrentConnection() throws {
        guard try store.load(server: server)?.id == connection.id else { throw BotFailure.stale }
    }

    private func watchDisconnect(_ client: any BotTransport, owner: Int) {
        client.onDisconnect = { [weak self] _ in
            guard let self, self.generation == owner else { return }
            self.wire = nil
        }
    }
}

/// A source's switchable lists, as read and as the sheet left them.
private struct SourceLists: Equatable {
    var skills: [BotProfileCapability] = []
    var toolsets: [BotProfileCapability] = []
    var plugins: [BotProfileCapability] = []
    var mcpServers: [BotProfileCapability] = []

    init() {}
    init(_ draft: BotCreator.Draft) {
        skills = draft.skills; toolsets = draft.toolsets; plugins = draft.plugins; mcpServers = draft.mcpServers
    }
}

/// Ends a create after a step recorded its own failure message.
private struct BotCreatorStop: Error {}
