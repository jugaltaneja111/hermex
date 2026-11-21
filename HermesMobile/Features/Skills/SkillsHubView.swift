import SwiftUI

struct SkillsHubView: View {
    @State private var model: SkillsHubModel
    private let onInstalled: () -> Void

    init(client: HermesSkillsHubClient, onInstalled: @escaping () -> Void) {
        _model = State(initialValue: SkillsHubModel(client: client))
        self.onInstalled = onInstalled
    }

    var body: some View {
        AppList {
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Discover Skills")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search skills..."))
        .onSubmit(of: .search) { Task { await model.load() } }
        .onChange(of: model.query.isEmpty) { _, isEmpty in
            if isEmpty { Task { await model.load() } }
        }
        .task { await model.load() }
        .alert("Couldn't Install Skill", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
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
                Text("Loading skills...")
            }
            .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load Skills", systemImage: "exclamationmark.triangle")
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
                Text("Installing skills needs a newer Hermes release. Update Hermes on your server, then try again.")
            }
            .listRowBackground(Color.clear)
        case .loaded:
            if model.skills.isEmpty {
                ContentUnavailableView.search(text: model.query)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.skills) { skill in
                        NavigationLink {
                            SkillsHubDetailView(skill: skill, model: model, onInstalled: onInstalled)
                        } label: {
                            row(skill)
                        }
                    }
                    if model.hasMore {
                        Button {
                            Task { await model.loadMore() }
                        } label: {
                            HStack {
                                Text("Load More")
                                Spacer()
                                if model.isLoadingMore { ProgressView() }
                            }
                        }
                        .disabled(model.isLoadingMore)
                    }
                } footer: {
                    Text("Skills are instructions your bot follows, written by other people. Read one before you install it.")
                }
            }
        }
    }

    private func row(_ skill: HermesHubSkill) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: skill.name)
                    .font(AppFont.body(weight: .medium))
                    .foregroundStyle(.appPrimary)
                if !skill.summary.isEmpty {
                    Text(verbatim: skill.summary)
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                        .lineLimit(2)
                }
                if let source = skill.source {
                    Text(verbatim: [source, skill.trust].compactMap { $0 }.joined(separator: " · "))
                        .font(AppFont.caption())
                        .foregroundStyle(.appTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.installed.contains(skill.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Installed"))
            }
        }
    }
}

private struct SkillsHubDetailView: View {
    let skill: HermesHubSkill
    let model: SkillsHubModel
    let onInstalled: () -> Void

    @State private var info: HermesHubSkillInfo?
    @State private var isLoading = true
    @State private var isConfirming = false

    var body: some View {
        let isInstalled = model.installed.contains(skill.id)
        AppList {
            Section {
                let summary = info?.summary ?? skill.summary
                if !summary.isEmpty { Text(verbatim: summary) }
                if let source = info?.source ?? skill.source {
                    LabeledContent("Source") {
                        Text(verbatim: [source, skill.trust].compactMap { $0 }.joined(separator: " · ")).textSelection(.enabled)
                    }
                }
                if let tags = info?.tags, !tags.isEmpty {
                    Text(verbatim: tags.joined(separator: ", "))
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                }
            }
            if isLoading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let preview = info?.preview {
                Section("Instructions") {
                    Text(verbatim: preview)
                        .font(AppFont.footnote())
                        .textSelection(.enabled)
                }
            }
            Section {
                if isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                } else {
                    Button {
                        isConfirming = true
                    } label: {
                        HStack {
                            Text("Install")
                            Spacer()
                            if model.installing == skill.id { ProgressView() }
                        }
                    }
                    .disabled(model.installing != nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            info = await model.info(for: skill)
            isLoading = false
        }
        .alert(Text("Install \(skill.name)?"), isPresented: $isConfirming) {
            Button("Install") {
                Task { if await model.install(skill) { onInstalled() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes downloads this skill onto your server for the \(model.profile) Profile, and its bot can then follow it.")
        }
    }
}
