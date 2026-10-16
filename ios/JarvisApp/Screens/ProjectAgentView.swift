import SwiftUI

/// Project & Coding Agent.
///
/// This screen works on a real repository through the GitHub API. It is built
/// around three promises:
///  * nothing is written to a repository without an explicit confirmation;
///  * every write is confined to a branch you name, then offered as a pull
///    request — never a force-push, never a rewrite of history;
///  * each step is reported individually, including failures, so you always know
///    the exact state of the repository afterwards.
public struct ProjectAgentView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var repositories: [GitHubRepository] = []
    @State private var selected: GitHubRepository?
    @State private var branchName = "jarvis/agent-work"
    @State private var instruction = ""
    @State private var proposal: CodingProposal?
    @State private var stepResults: [GitHubStepResult] = []
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var confirmApply = false
    @State private var confirmIssue = false

    public init() {}

    private var bridge: GitHubBridge? {
        environment.integrations.map { GitHubBridge(client: $0.github) }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                connectionCard
                if selected != nil { branchCard }
                planCard
                if let proposal { proposalCard(proposal) }
                if !stepResults.isEmpty { resultsCard }
                if let statusMessage { InlineBanner(kind: .success, title: "Done", message: statusMessage) }
                if let errorMessage { InlineBanner(kind: .error, title: "Coding agent", message: errorMessage) }
                honestyCard
            }
            .padding(JarvisTheme.Spacing.m)
        }
        .background(AmbientBackground())
        .navigationTitle("Project agent")
        .task { await loadRepositories() }
        .confirmationDialog("Apply this plan to \(selected?.fullName ?? "the repository")?",
                            isPresented: $confirmApply, titleVisibility: .visible) {
            Button("Create branch and pull request", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("JARVIS will create the branch “\(branchName)”, commit the plan document to it, and open a pull request against \(selected?.defaultBranch ?? "the default branch"). Nothing is merged, and no existing branch is modified.")
        }
        .confirmationDialog("Create an issue with this plan?",
                            isPresented: $confirmIssue, titleVisibility: .visible) {
            Button("Create issue") { Task { await createIssue() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This posts a new issue to \(selected?.fullName ?? "the repository"). It is visible to anyone with access to the repository.")
        }
    }

    // MARK: Cards

    private var connectionCard: some View {
        GlassCard(title: "Repository", subtitle: "Read through the GitHub REST API with your own token") {
            if isLoading {
                LoadingDots()
            } else if repositories.isEmpty {
                Text("No repositories loaded. Add a GitHub token in Settings ▸ Permissions & connections, then reload.")
                    .font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                GlassButton("Reload repositories", systemImage: "arrow.clockwise", style: .secondary) {
                    Task { await loadRepositories() }
                }
            } else {
                Picker("Repository", selection: $selected) {
                    Text("Select…").tag(GitHubRepository?.none)
                    ForEach(repositories) { repository in
                        Text(repository.fullName).tag(GitHubRepository?.some(repository))
                    }
                }
                .pickerStyle(.menu)
                .tint(JarvisTheme.Palette.ice)

                if let selected {
                    HStack(spacing: 6) {
                        StatusPill(text: selected.isPrivate ? "private" : "public",
                                   systemImage: selected.isPrivate ? "lock.fill" : "globe",
                                   tint: selected.isPrivate ? JarvisTheme.Palette.silver : JarvisTheme.Palette.mint)
                        StatusPill(text: selected.defaultBranch, systemImage: "arrow.triangle.branch",
                                   tint: JarvisTheme.Palette.ice)
                    }
                    if let description = selected.description {
                        Text(description).font(JarvisTheme.Typography.caption)
                            .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    }
                    if let url = URL(string: selected.htmlURL) {
                        Link("Open on GitHub", destination: url)
                            .font(JarvisTheme.Typography.micro)
                            .tint(JarvisTheme.Palette.ice)
                    }
                }
            }
        }
    }

    private var branchCard: some View {
        GlassCard(title: "Working branch", subtitle: "JARVIS only ever writes to a branch it creates") {
            TextField("jarvis/agent-work", text: $branchName)
                .font(JarvisTheme.Typography.timer)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: JarvisTheme.Radius.medium, style: .continuous)
                        .fill(JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
                }
        }
    }

    private var planCard: some View {
        GlassCard(title: "Task", subtitle: "Describe the change in plain language") {
            TextField("e.g. Document the free-tier providers in the README", text: $instruction, axis: .vertical)
                .font(JarvisTheme.Typography.body)
                .lineLimit(2...6)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: JarvisTheme.Radius.medium, style: .continuous)
                        .fill(JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
                }
            HStack(spacing: JarvisTheme.Spacing.s) {
                GlassButton("Draft a plan", systemImage: "wand.and.stars", style: .primary) {
                    Task { await draftPlan() }
                }
                .disabled(selected == nil || instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                if proposal != nil {
                    GlassButton("Discard", systemImage: "xmark", style: .secondary) {
                        proposal = nil; stepResults = []
                    }
                }
            }
            Text("The agent uses the provider you configured. It reads the repository to ground the plan, and refuses to claim any change it has not made.")
                .font(JarvisTheme.Typography.micro)
                .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func proposalCard(_ proposal: CodingProposal) -> some View {
        GlassCard(title: "Proposed change", subtitle: "Nothing has been written yet") {
            Text(proposal.summary)
                .font(JarvisTheme.Typography.body)
                .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(proposal.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6)
                        .foregroundStyle(JarvisTheme.Palette.ice)
                    Text(step).font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isWorking { LoadingDots() }
            HStack(spacing: JarvisTheme.Spacing.s) {
                GlassButton("Apply on branch…", systemImage: "arrow.triangle.branch", style: .destructive,
                            isEnabled: !isWorking,
                            disabledReason: isWorking ? "A run is already in progress." : nil) {
                    confirmApply = true
                }
                GlassButton("Create issue…", systemImage: "doc.badge.plus", style: .secondary,
                            isEnabled: !isWorking) {
                    confirmIssue = true
                }
            }
        }
    }

    private var resultsCard: some View {
        GlassCard(title: "Run log", subtitle: "In order, exactly as it happened") {
            ForEach(stepResults) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(step.succeeded ? JarvisTheme.Palette.mint : JarvisTheme.Palette.rose)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(JarvisTheme.Typography.caption)
                            .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                        Text(step.detail).font(JarvisTheme.Typography.micro)
                            .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var honestyCard: some View {
        GlassCard(title: "What this agent does not do") {
            Text("""
            It does not push to your default branch, force-push, rewrite history, merge pull requests, or touch repositories you have not selected. \
            It cannot run your build or tests — nothing is claimed as tested. \
            Editing arbitrary source files by model output is deliberately not offered: the model drafts, you review, GitHub tracks the diff.
            """)
            .font(JarvisTheme.Typography.micro)
            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func loadRepositories() async {
        guard let bridge else { errorMessage = "Integrations are unavailable in this build."; return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            repositories = try await bridge.repositories(limit: 60)
            if repositories.isEmpty {
                errorMessage = "The token works, but it cannot see any repositories. Check the token's scopes (repo, read:user)."
            }
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func draftPlan() async {
        guard let orchestrator = environment.orchestrator, let repository = selected else { return }
        guard environment.providerState.isUsable else {
            errorMessage = environment.providerState.explanation
            return
        }
        errorMessage = nil; statusMessage = nil; stepResults = []
        isWorking = true
        defer { isWorking = false }

        let prompt = """
        Repository: \(repository.fullName) (default branch: \(repository.defaultBranch))
        Working branch: \(branchName)
        Task: \(instruction)

        Write a short, concrete plan of 3–6 steps for this change, as a plain list. \
        Do not claim any change has been made. If the task requires editing source files, say which files.
        """
        var text = ""
        do {
            for try await event in orchestrator.send(prompt, sessionID: nil) {
                if case .textDelta(let delta) = event { text += delta }
            }
            let steps = text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*0123456789.\t")) }
                .filter { $0.count > 3 }
            proposal = CodingProposal(repository: repository.fullName,
                                      branch: branchName,
                                      summary: text.isEmpty ? "The provider returned no plan." : String(text.prefix(400)),
                                      steps: Array(steps.prefix(8)))
            if text.isEmpty { errorMessage = "The provider returned an empty response. Check the provider test in Settings ▸ AI Providers." }
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply() async {
        guard let bridge, let repository = selected, let proposal else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil; statusMessage = nil; stepResults = []
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let path = "docs/jarvis-agent/plan-\(stamp).md"
        do {
            stepResults = try await bridge.applyPlan(repository: repository,
                                                     branch: branchName,
                                                     baseBranch: repository.defaultBranch,
                                                     planText: planDocument(proposal),
                                                     path: path)
            if stepResults.allSatisfy({ $0.succeeded }) {
                statusMessage = "Branch “\(branchName)” now contains the plan and a pull request is open for review."
                Haptics.success()
            } else {
                statusMessage = "Completed with failures — see the run log above. Nothing was merged."
                Haptics.warning()
            }
        } catch let error as JarvisError {
            errorMessage = error.userMessage
            Haptics.error()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func createIssue() async {
        guard let bridge, let repository = selected, let proposal else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let issue = try await bridge.createIssue(repository: repository.fullName,
                                                     title: String(instruction.prefix(80)),
                                                     body: planDocument(proposal))
            statusMessage = "Issue #\(issue.number) created: \(issue.htmlURL)"
            Haptics.success()
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func planDocument(_ proposal: CodingProposal) -> String {
        """
        # JARVIS agent plan

        **Repository:** \(proposal.repository)
        **Branch:** \(proposal.branch)
        **Requested by:** the owner of this device, through the JARVIS Project Agent screen
        **Generated:** \(Date().iso8601)

        ## Task

        \(instruction)

        ## Draft

        \(proposal.summary)

        ## Steps

        \(proposal.steps.map { "- \($0)" }.joined(separator: "\n"))

        > This document was written by JARVIS. No source file was modified: the change is
        > proposed for human review. Verify before merging.
        """
    }
}

/// A drafted plan. Nothing in here has been applied yet, and the UI says so.
struct CodingProposal {
    var repository: String
    var branch: String
    var summary: String
    var steps: [String]
}
