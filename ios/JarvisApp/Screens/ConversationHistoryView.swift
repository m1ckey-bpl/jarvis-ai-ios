import SwiftUI

/// Browse and search past conversations. History is local and deletable.
public struct ConversationHistoryView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var sessions: [ConversationSession] = []
    @State private var query = ""
    @State private var selected: ConversationSession?
    @State private var matches: [ConversationMessage] = []
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                searchBar
                if !query.isEmpty {
                    if matches.isEmpty {
                        EmptyStateView(title: "No matches", message: "Nothing in your history contains “\(query)”.",
                                       systemImage: "text.magnifyingglass")
                    } else {
                        SectionHeader("Matching messages", subtitle: "\(matches.count) result(s)")
                        ForEach(matches) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role.rawValue.uppercased())
                                    .font(JarvisTheme.Typography.micro).tracking(1)
                                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                                Text(message.text)
                                    .font(JarvisTheme.Typography.caption)
                                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                                    .lineLimit(4)
                                Text(message.createdAt.relativeDescription())
                                    .font(JarvisTheme.Typography.micro)
                                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                            }
                            .padding(JarvisTheme.Spacing.m)
                            .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
                        }
                    }
                } else if sessions.isEmpty {
                    EmptyStateView(title: "No conversations yet",
                                   message: "Your conversations are stored on this device only. Start one from the Assistant tab.",
                                   systemImage: "bubble.left.and.bubble.right")
                } else {
                    SectionHeader("Sessions", subtitle: "Stored locally, deletable at any time")
                    ForEach(sessions) { session in
                        Button { selected = session } label: {
                            HStack(spacing: JarvisTheme.Spacing.s) {
                                Image(systemName: "bubble.left.fill")
                                    .foregroundStyle(JarvisTheme.Palette.ice)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .font(JarvisTheme.Typography.callout)
                                        .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                                    Text(session.updatedAt.relativeDescription())
                                        .font(JarvisTheme.Typography.micro)
                                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                            }
                            .padding(JarvisTheme.Spacing.m)
                            .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let errorMessage {
                    InlineBanner(kind: .error, title: "History", message: errorMessage)
                }
            }
            .padding(JarvisTheme.Spacing.m)
        }
        .background(AmbientBackground())
        .navigationTitle("History")
        .sheet(item: $selected) { session in
            SessionDetailSheet(session: session)
        }
        .task { await reload() }
    }

    private var searchBar: some View {
        HStack(spacing: JarvisTheme.Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            TextField("Search conversations", text: $query)
                .font(JarvisTheme.Typography.body)
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
            if !query.isEmpty {
                Button { query = ""; matches = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .jarvisGlass(.strong, cornerRadius: JarvisTheme.Radius.pill)
    }

    private func reload() async {
        guard let conversations = environment.conversations else {
            errorMessage = "Conversation storage is unavailable."
            return
        }
        do { sessions = try conversations.sessions(limit: 200) }
        catch { errorMessage = error.localizedDescription }
    }

    private func search() async {
        guard let conversations = environment.conversations, !query.isEmpty else { matches = []; return }
        do { matches = try conversations.search(query, limit: 60) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct SessionDetailSheet: View {
    let session: ConversationSession
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var messages: [ConversationMessage] = []
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.s) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.role.rawValue.uppercased())
                                .font(JarvisTheme.Typography.micro).tracking(1)
                                .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                            Text(message.text)
                                .font(JarvisTheme.Typography.body)
                                .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                                .textSelection(.enabled)
                            if let tools = message.toolCallSummary {
                                Text("tools: \(tools)")
                                    .font(JarvisTheme.Typography.micro)
                                    .foregroundStyle(JarvisTheme.Palette.cyan)
                            }
                        }
                        .padding(JarvisTheme.Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
            .background(AmbientBackground())
            .navigationTitle(session.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showDeleteConfirm = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete conversation")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete this conversation?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    try? environment.conversations?.delete(sessionID: session.id)
                    dismiss()
                }
            }
            .task { messages = (try? environment.conversations?.messages(sessionID: session.id, limit: 500)) ?? [] }
        }
    }
}
