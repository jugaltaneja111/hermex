import SwiftUI

/// A Hermes server's MCP Servers page, opened from its Settings page: the servers one Profile's
/// config has, each opening to its test, key and removal, then the host's presets and a form
/// for a server by web address. Keys typed here go to the host's `.env` and are not kept.
struct MCPServersView: View {
    @State private var model: MCPServersModel
    @State private var showsCustom = false
    @State private var keyed: HermesMCPPreset?
    /// A refusal from the keys sheet, held until the sheet is gone: an alert can't show under it.
    @State private var heldError: String?

    /// `profile` opens on that Profile, as the bot editor does; nil starts on the host's default.
    init(connection: BotConnection, server: URL, profile: String? = nil) {
        _model = State(initialValue: MCPServersModel(client: HermesMCPClient(saved: connection, server: server), profile: profile))
    }

    var body: some View {
        AppList {
            if let profile = model.profile {
                ServerProfileRow(profiles: model.profiles, selection: profile,
                                 footer: "MCP servers give this Profile's bot more tools.") { name in
                    Task { await model.select(name) }
                }
                .disabled(model.busy != nil)
            }
            content
        }
        .settingsPage(String(localized: "MCP Servers"))
        .listSectionSpacing(.compact)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Server", systemImage: "plus") { showsCustom = true }
                    .disabled(model.state != .loaded || model.busy != nil)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $showsCustom) { MCPCustomServerSheet(model: model) }
        .sheet(item: $keyed, onDismiss: {
            if let heldError { model.actionError = heldError }
            heldError = nil
        }) { preset in
            MCPPresetKeysSheet(model: model, preset: preset) { heldError = $0 }
        }
        .alert("Couldn't Update MCP Servers", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading…")
            }
            .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load MCP Servers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .unsupported:
            ContentUnavailableView {
                Label("This Hermes Is Too Old", systemImage: "arrow.up.circle")
            } description: {
                Text("MCP servers need a newer Hermes release. Update Hermes on your server, then refresh.")
            } actions: {
                Button("Refresh") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        Section("Added") {
            if model.servers.isEmpty {
                Text("No MCP servers on this Profile yet.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.appSecondary)
            }
            ForEach(model.servers) { server in
                NavigationLink {
                    MCPServerDetailView(name: server.name, model: model)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: server.name)
                            .font(AppFont.body(weight: .medium))
                            .foregroundStyle(.appPrimary)
                        if let address = server.address {
                            Text(verbatim: address)
                                .font(AppFont.footnote())
                                .foregroundStyle(.appSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        if !model.presets.isEmpty {
            Section("Ready to Add") {
                ForEach(model.presets) { preset in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: preset.name)
                                .font(AppFont.body(weight: .medium))
                                .foregroundStyle(.appPrimary)
                            if !preset.summary.isEmpty {
                                Text(verbatim: preset.summary)
                                    .font(AppFont.footnote())
                                    .foregroundStyle(.appSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        if model.busy == preset.name {
                            ProgressView()
                        } else {
                            Button {
                                if preset.requires.isEmpty { Task { await model.add(preset) } } else { keyed = preset }
                            } label: {
                                Text("Add")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .font(AppFont.footnote(weight: .semibold))
                            .disabled(model.busy != nil)
                            .accessibilityLabel(Text("Add") + Text(verbatim: ", \(preset.name)"))
                        }
                    }
                }
            }
        }
    }
}

/// One server: where it runs, a connection test, its key, and its removal. A server a plugin
/// provides shows only the test. The page closes when the server leaves the list.
private struct MCPServerDetailView: View {
    let name: String
    let model: MCPServersModel

    @State private var key = ""
    @State private var isConfirmingRemoval = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let server = model.server(name)
        AppList {
            if let server {
                Section {
                    if let address = server.address {
                        Text(verbatim: address)
                            .font(AppFont.footnote())
                            .foregroundStyle(.appSecondary)
                            .textSelection(.enabled)
                    }
                    if let plugin = server.plugin {
                        Text("Provided by the \(plugin) plugin. Change it in Plugins.")
                            .font(AppFont.footnote())
                            .foregroundStyle(.appSecondary)
                    }
                    if !server.isEnabled {
                        Text("Turned off for this Profile. Turn it on in the bot's settings.")
                            .font(AppFont.footnote())
                            .foregroundStyle(.appSecondary)
                    }
                }
                Section {
                    Button {
                        Task { await model.test(server) }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if model.busy == server.name { ProgressView() }
                        }
                    }
                    .disabled(model.busy != nil)
                    if let test = model.tests[server.name] { result(test) }
                }
                if server.takesKey {
                    Section {
                        SecureField("API key or token", text: $key)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save Key") {
                            let value = key
                            Task { if await model.setKey(value, for: server) { key = "" } }
                        }
                        .disabled(key.isEmpty || model.busy != nil)
                    } footer: {
                        Text("Saved in this Profile's keys on the server, and not kept on this iPhone.")
                    }
                } else if server.usesOAuth, server.isEditable {
                    Section {
                        Text("This server signs in through a browser. Finish that sign-in in Hermes on the server's own machine.")
                            .font(AppFont.footnote())
                            .foregroundStyle(.appSecondary)
                    }
                }
                if server.isEditable {
                    Section {
                        Button("Remove Server", role: .destructive) { isConfirmingRemoval = true }
                            .disabled(model.busy != nil)
                    }
                }
            }
        }
        .settingsPage(name)
        .alert(Text("Remove \(name)?"), isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) {
                guard let server else { return }
                Task { await model.remove(server) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(model.profile ?? "") Profile's bot loses this server's tools. A key saved for it stays on the server.")
        }
        .onChange(of: server == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }

    @ViewBuilder
    private func result(_ test: HermesMCPTest) -> some View {
        if test.isConnected {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                    Text("Tools: \(test.tools)")
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(test.needsSignIn ? "Sign-in needed" : "Didn't connect")
                    if let error = test.error {
                        Text(verbatim: error)
                            .font(AppFont.footnote())
                            .foregroundStyle(.appSecondary)
                            .textSelection(.enabled)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
        }
    }
}

/// The keys a preset needs before it can connect, one field each, named as the host names them.
/// A field left empty is skipped: the server is added and can get its key later.
private struct MCPPresetKeysSheet: View {
    let model: MCPServersModel
    let preset: HermesMCPPreset
    /// Takes a refusal for the page to show once this sheet has closed.
    let onRefusal: (String) -> Void

    @State private var keys: [String: String] = [:]
    @State private var isAdding = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    ForEach(preset.requires, id: \.self) { name in
                        SecureField(name, text: Binding(get: { keys[name] ?? "" }, set: { keys[name] = $0 }))
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Saved in this Profile's keys on the server, and not kept on this iPhone.")
                }
            }
            .themedPageBackground()
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isAdding)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        isAdding = true
                        Task {
                            // The list is read again either way, so the sheet always closes: a
                            // server added without its key is finished from its own page.
                            if !(await model.add(preset, keys: keys)), let refusal = model.actionError {
                                model.actionError = nil
                                onRefusal(refusal)
                            }
                            dismiss()
                        }
                    }
                    .disabled(isAdding)
                }
            }
        }
        .interactiveDismissDisabled(isAdding)
    }
}

/// A server by web address: a name, its URL and the bearer token it asks for, if any. A command
/// for the host to run is not offered from the phone.
private struct MCPCustomServerSheet: View {
    let model: MCPServersModel

    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var isAdding = false
    /// The host's refusal, shown here: the page's alert can't show under this sheet.
    @State private var refusal: String?
    @Environment(\.dismiss) private var dismiss

    /// The address as a web URL, or nil while it isn't one.
    private var url: URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            AppList {
                if let refusal {
                    Section {
                        Label {
                            Text(verbatim: refusal)
                        } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                    }
                }
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Server URL", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    SecureField("Bearer token (optional)", text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Saved in this Profile's keys on the server, and not kept on this iPhone.")
                }
            }
            .themedPageBackground()
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isAdding)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let url else { return }
                        isAdding = true
                        Task {
                            // A refusal stays on the sheet, so nothing is retyped.
                            refusal = nil
                            if await model.add(name: name, url: url, token: token) {
                                dismiss()
                            } else {
                                refusal = model.actionError
                                model.actionError = nil
                            }
                            isAdding = false
                        }
                    }
                    .disabled(isAdding || url == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isAdding)
    }
}
