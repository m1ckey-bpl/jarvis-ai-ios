import SwiftUI

/// Tool Execution History: exactly what ran, with which arguments (secrets
/// redacted before writing), whether it succeeded, and how long it took.
public struct ToolHistoryView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var runs: [ToolExecutionLog.Entry] = []
    @State private var errorMessage: String?
    @State private var selected: ToolExecutionLog.Entry?
    @State private var filter: String?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                if !runs.isEmpty { toolFilter }
                if runs.isEmpty {
                    EmptyStateView(title: "No tool runs yet",
                                   message: "When JARVIS uses a tool — checking the time, reading your calendar, creating a draft — the run is recorded here with its result.",
                                   systemImage: "wrench.and.screwdriver")
                } else if visible.isEmpty {
                    EmptyStateView(title: "Nothing matches",
                                   message: "No runs of “\(filter ?? "")” were found.",
                                   systemImage: "line.3.horizontal.decrease.circle",
                                   actionTitle: "Show all tools",
                                   action: { filter = nil })
                } else {
                    SectionHeader("Recent runs", subtitle: "Newest first · \(visible.count) of \(runs.count) recorded")
                    ForEach(visible) { run in
                        Button { selected = run } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    StatusPill(text: run.toolName, systemImage: "bolt.horizontal", tint: run.statusColor)
                                    if run.risk != .safe {
                                        StatusPill(text: run.risk.displayName, systemImage: "exclamationmark.shield", tint: JarvisTheme.Palette.amber)
                                    }
                                    Spacer(minLength: 0)
                                    Text(run.startedAt.relativeDescription())
                                        .font(JarvisTheme.Typography.micro)
                                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                                }
                                Text(run.summary)
                                    .font(JarvisTheme.Typography.caption)
                                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                                    .lineLimit(2)
                                HStack(spacing: 10) {
                                    Text(run.statusLabel)
                                    Text(String(format: "%.2f s", run.durationSeconds))
                                    if run.confirmedByUser { Text("confirmed by you") }
                                }
                                .font(JarvisTheme.Typography.micro)
                                .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                            }
                            .padding(JarvisTheme.Spacing.m)
                            .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let errorMessage {
                    InlineBanner(kind: .error, title: "Tool log", message: errorMessage)
                }
            }
            .padding(JarvisTheme.Spacing.m)
        }
        .background(AmbientBackground())
        .navigationTitle("Tool history")
        .sheet(item: $selected) { run in ToolRunDetailSheet(run: run) }
        .task { await reload() }
    }

    private var toolFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JarvisTheme.Spacing.xs) {
                chip(title: "All", active: filter == nil) { filter = nil }
                ForEach(names, id: \.self) { name in
                    chip(title: name, active: filter == name) { filter = (filter == name ? nil : name) }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(JarvisTheme.Motion.snappy) { action() }
        } label: {
            Text(title)
                .font(JarvisTheme.Typography.micro)
                .foregroundStyle(active ? JarvisTheme.Palette.ink : JarvisTheme.Palette.secondaryText(scheme))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background {
                    Capsule().fill(active ? JarvisTheme.Palette.ice.opacity(0.9)
                                          : JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
                }
        }
        .buttonStyle(.plain)
    }

    private var names: [String] {
        Array(Set(runs.map { $0.toolName })).sorted()
    }

    private var visible: [ToolExecutionLog.Entry] {
        guard let filter else { return runs }
        return runs.filter { $0.toolName == filter }
    }

    private func reload() async {
        guard let log = environment.toolLog else { errorMessage = "The tool log is unavailable in this build."; return }
        do { runs = try log.recent(limit: 200) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct ToolRunDetailSheet: View {
    let run: ToolExecutionLog.Entry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                    GlassCard(title: run.toolName,
                              subtitle: run.startedAt.formatted(date: .abbreviated, time: .standard)) {
                        LabeledContent("Result", value: run.statusLabel)
                        LabeledContent("Risk", value: run.risk.displayName)
                        LabeledContent("Confirmed by you", value: run.confirmedByUser ? "yes" : "no")
                        LabeledContent("Verified by service", value: run.verified ? "yes" : "no — the tool reported this itself")
                        LabeledContent("Duration", value: String(format: "%.2f s", run.durationSeconds))
                    }
                    GlassCard(title: "Arguments", subtitle: "Secrets are redacted before logging") {
                        Text(run.argumentsJSON.isEmpty ? "—" : run.argumentsJSON)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                            .textSelection(.enabled)
                    }
                    GlassCard(title: run.success ? "Result" : "Error") {
                        Text(run.summary)
                            .font(JarvisTheme.Typography.caption)
                            .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                            .textSelection(.enabled)
                        if let error = run.errorMessage, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(JarvisTheme.Palette.danger)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
            .background(AmbientBackground())
            .navigationTitle("Tool run")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
