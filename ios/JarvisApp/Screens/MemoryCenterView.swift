import SwiftUI

/// Memory Center: inspect, search, correct, forget and export everything JARVIS knows.
public struct MemoryCenterView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var records: [MemoryRecord] = []
    @State private var query = ""
    @State private var kindFilter: MemoryKind?
    @State private var editing: MemoryRecord?
    @State private var exportText: String?
    @State private var errorMessage: String?
    @State private var showEraseConfirm = false
    @State private var isLoading = true

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                    searchBar
                    filterRow
                    if isLoading {
                        LoadingDots().frame(maxWidth: .infinity).padding(.top, JarvisTheme.Spacing.l)
                    } else if !filtered.isEmpty {
                        ForEach(filtered) { record in
                            MemoryRow(record: record,
                                      onCorrect: { editing = record },
                                      onForget: { Task { await forget(record) } })
                        }
                    } else {
                        EmptyStateView(
                            title: query.isEmpty ? "Nothing remembered yet" : "No matches",
                            message: query.isEmpty
                                ? "Ask JARVIS to remember something — “remember that my preferred language is English” — and it will appear here, on this device only."
                                : "No memory matches “\(query)”. Try a different word or clear the filter.",
                            systemImage: "brain.head.profile",
                            actionTitle: query.isEmpty ? nil : "Clear search",
                            action: query.isEmpty ? nil : { query = "" }
                        )
                    }
                    if let errorMessage {
                        InlineBanner(kind: .error, title: "Memory error", message: errorMessage)
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
            .background(AmbientBackground())
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await export() }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export memory")

                    Menu {
                        Button("Erase everything…", role: .destructive) { showEraseConfirm = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Erase all memories?",
                                isPresented: $showEraseConfirm,
                                titleVisibility: .visible) {
                Button("Erase all \(records.count) memories", role: .destructive) { Task { await eraseAll() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every stored memory from this device. Conversations and reminders are not affected.")
            }
            .sheet(item: $editing) { record in
                MemoryEditSheet(record: record) { newText in
                    Task { await correct(record, to: newText) }
                }
            }
            .sheet(isPresented: Binding(get: { exportText != nil }, set: { if !$0 { exportText = nil } })) {
                MemoryExportSheet(text: exportText ?? "")
            }
            .task { await reload() }
        }
    }

    // MARK: Pieces

    private var searchBar: some View {
        HStack(spacing: JarvisTheme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            TextField("Search memory", text: $query)
                .font(JarvisTheme.Typography.body)
                .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                .submitLabel(.search)
                .onSubmit { Task { await reload() } }
            if !query.isEmpty {
                Button { query = ""; Task { await reload() } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .jarvisGlass(.strong, cornerRadius: JarvisTheme.Radius.pill)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JarvisTheme.Spacing.xs) {
                filterChip(title: "All", isSelected: kindFilter == nil) { kindFilter = nil }
                ForEach(MemoryKind.allCases, id: \.self) { kind in
                    if !records.filter({ $0.kind == kind }).isEmpty {
                        filterChip(title: kind.displayName, isSelected: kindFilter == kind) { kindFilter = kind }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            withAnimation(JarvisTheme.Motion.snappy) { action() }
        } label: {
            Text(title)
                .font(JarvisTheme.Typography.micro)
                .foregroundStyle(isSelected ? JarvisTheme.Palette.ink : JarvisTheme.Palette.secondaryText(scheme))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background {
                    Capsule().fill(isSelected ? JarvisTheme.Palette.ice.opacity(0.9)
                                              : JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

    private var filtered: [MemoryRecord] {
        var items = records
        if let kindFilter { items = items.filter { $0.kind == kindFilter } }
        if !query.isEmpty {
            let needle = query.lowercased()
            items = items.filter {
                $0.text.lowercased().contains(needle)
                || ($0.subject ?? "").lowercased().contains(needle)
                || $0.tags.joined(separator: " ").lowercased().contains(needle)
            }
        }
        return items
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        guard let memory = environment.memory else { errorMessage = "Memory storage is unavailable."; return }
        do {
            records = try memory.all(includeInactive: false).sorted { $0.updatedAt > $1.updatedAt }
            // A search term also consults the retrieval engine for ranked matches.
            if !query.isEmpty {
                let ranked = try memory.retrieve(query, limit: 25).map { $0.record }
                var merged = ranked
                for record in records where !merged.contains(where: { $0.id == record.id }) {
                    if filtered.contains(where: { $0.id == record.id }) { merged.append(record) }
                }
                if !ranked.isEmpty { records = merged }
            }
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func correct(_ record: MemoryRecord, to newText: String) async {
        guard let memory = environment.memory else { return }
        do {
            _ = try memory.correct(id: record.id, newText: newText)
            Haptics.success()
            await reload()
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func forget(_ record: MemoryRecord) async {
        guard let memory = environment.memory else { return }
        do {
            try memory.forget(id: record.id)
            Haptics.tap()
            await reload()
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func eraseAll() async {
        guard let memory = environment.memory else { return }
        do {
            try memory.forgetAll()
            Haptics.warning()
            await reload()
        } catch {
            errorMessage = "Could not erase memories: \(error.localizedDescription)"
        }
    }

    private func export() async {
        guard let memory = environment.memory else { return }
        exportText = (try? memory.export(format: .markdown)) ?? "Export failed."
    }
}

private struct MemoryRow: View {
    let record: MemoryRecord
    let onCorrect: () -> Void
    let onForget: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: JarvisTheme.Spacing.s) {
            HStack(spacing: 6) {
                StatusPill(text: record.kind.displayName,
                           systemImage: icon, tint: tint)
                if record.locked {
                    StatusPill(text: "instruction", systemImage: "lock.fill", tint: JarvisTheme.Palette.cyan)
                }
                if record.source.isUntrusted {
                    StatusPill(text: "external", systemImage: "globe", tint: JarvisTheme.Palette.warning)
                }
                Spacer(minLength: 0)
                Text("\(Int(record.confidence * 100))%")
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            }

            Text(record.text)
                .font(JarvisTheme.Typography.body)
                .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: JarvisTheme.Spacing.s) {
                Text("updated \(record.updatedAt.relativeDescription())")
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                Spacer(minLength: 0)
                Button("Correct", action: onCorrect)
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.ice)
                Button("Forget", action: onForget)
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.danger)
            }
        }
        .padding(JarvisTheme.Spacing.m)
        .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch record.kind {
        case .instruction: return "lock.fill"
        case .preference: return "heart.fill"
        case .goal: return "flag.fill"
        case .importantDate: return "calendar"
        case .decision: return "checkmark.seal.fill"
        case .task: return "checklist"
        case .correction: return "pencil.circle.fill"
        case .summary: return "text.append"
        case .inference: return "sparkles"
        case .fact: return "info.circle.fill"
        }
    }

    private var tint: SwiftUI.Color {
        switch record.kind {
        case .instruction: return JarvisTheme.Palette.cyan
        case .preference: return JarvisTheme.Palette.mint
        case .goal: return JarvisTheme.Palette.amber
        case .importantDate: return JarvisTheme.Palette.ice
        case .inference: return JarvisTheme.Palette.tertiaryText(.dark)
        default: return JarvisTheme.Palette.silver
        }
    }
}

private struct MemoryEditSheet: View {
    let record: MemoryRecord
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(record: MemoryRecord, onSave: @escaping (String) -> Void) {
        self.record = record
        self.onSave = onSave
        _text = State(initialValue: record.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Corrected memory") {
                    TextEditor(text: $text).frame(minHeight: 120)
                }
                Section {
                    Text("The previous version is kept as a superseded record so the change is auditable.")
                        .font(JarvisTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Correct memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
            }
        }
    }
}

private struct MemoryExportSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(JarvisTheme.Spacing.m)
            }
            .navigationTitle("Memory export")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
