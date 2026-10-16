import SwiftUI

/// Reminders and tasks: schedule, edit, complete, cancel — time-zone aware.
public struct TasksView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var scope: Scope = .upcoming
    @State private var reminders: [Reminder] = []
    @State private var newText = ""
    @State private var errorMessage: String?
    @State private var editing: Reminder?
    @State private var isCreating = false

    public enum Scope: String, CaseIterable, Identifiable {
        case today, tomorrow, upcoming, done
        public var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                    permissionBanner
                    createCard
                    scopePicker
                    if reminders.isEmpty {
                        EmptyStateView(
                            title: scope == .done ? "Nothing completed yet" : "No reminders here",
                            message: scope == .done
                                ? "Completed reminders appear here."
                                : "Try: “remind me tomorrow at 9am to study” or “remind me every Sunday at 6pm to review my projects”.",
                            systemImage: "checklist"
                        )
                    } else {
                        ForEach(reminders) { reminder in
                            ReminderRow(reminder: reminder,
                                        onComplete: { Task { await complete(reminder) } },
                                        onEdit: { editing = reminder },
                                        onCancel: { Task { await cancel(reminder) } })
                        }
                    }
                    if let errorMessage {
                        InlineBanner(kind: .error, title: "Reminders", message: errorMessage)
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
            .background(AmbientBackground())
            .navigationTitle("Tasks")
            .task { await reload() }
            .sheet(item: $editing) { reminder in
                ReminderEditSheet(reminder: reminder) { title, date, notes in
                    Task { await update(reminder, title: title, dueAt: date, notes: notes) }
                }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var permissionBanner: some View {
        let state = environment.capability(CapabilityID.reminders)
        if !state.isUsable {
            InlineBanner(kind: .warning, title: "Notifications are off",
                         message: state.explanation,
                         actionTitle: "Request permission",
                         action: {
                             Task {
                                 let result = await environment.reminderEngine?.requestAuthorization()
                                 if result?.isUsable != true { errorMessage = result?.explanation }
                                 await environment.refreshCapabilities()
                             }
                         })
        }
    }

    private var createCard: some View {
        GlassCard(title: "New reminder", subtitle: "Natural language works here — “every Friday at 7pm to call home”") {
            HStack(spacing: JarvisTheme.Spacing.s) {
                TextField("Remind me to…", text: $newText)
                    .font(JarvisTheme.Typography.body)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    .submitLabel(.done)
                    .onSubmit { Task { await create() } }
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().tint(JarvisTheme.Palette.ink) }
                    else { Image(systemName: "plus.circle.fill").font(.system(size: 24)) }
                }
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                .foregroundStyle(JarvisTheme.Palette.ice)
                .accessibilityLabel("Add reminder")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: JarvisTheme.Radius.medium, style: .continuous)
                    .fill(JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
            }
        }
    }

    private var scopePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JarvisTheme.Spacing.xs) {
                ForEach(Scope.allCases) { item in
                    Button {
                        Haptics.selection()
                        scope = item
                        Task { await reload() }
                    } label: {
                        Text(item.title)
                            .font(JarvisTheme.Typography.micro)
                            .foregroundStyle(scope == item ? JarvisTheme.Palette.ink : JarvisTheme.Palette.secondaryText(scheme))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background {
                                Capsule().fill(scope == item
                                               ? JarvisTheme.Palette.ice.opacity(0.9)
                                               : JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Actions

    private func reload() async {
        guard let engine = environment.reminderEngine else {
            errorMessage = "Reminders are unavailable."
            return
        }
        do {
            switch scope {
            case .today: reminders = try engine.today()
            case .tomorrow: reminders = try engine.tomorrow()
            case .upcoming: reminders = try engine.upcoming(limit: 50)
            case .done:
                let closed = try environment.reminderStore?.all(includeClosed: true) ?? []
                reminders = closed
                    .filter { $0.completedAt != nil }
                    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            }
            errorMessage = nil
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create() async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine = environment.reminderEngine else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let receipt = try await engine.create(fromNaturalLanguage: text)
            newText = ""
            Haptics.success()
            if !receipt.notificationConfirmed { errorMessage = receipt.note }
            await reload()
        } catch let error as JarvisError {
            errorMessage = error.userMessage
            Haptics.error()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func complete(_ reminder: Reminder) async {
        guard let engine = environment.reminderEngine else { return }
        do {
            _ = try await engine.complete(id: reminder.id)
            Haptics.success()
            await reload()
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel(_ reminder: Reminder) async {
        guard let engine = environment.reminderEngine else { return }
        do {
            try await engine.cancel(id: reminder.id)
            Haptics.tap()
            await reload()
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(_ reminder: Reminder, title: String, dueAt: Date, notes: String?) async {
        guard let engine = environment.reminderEngine else { return }
        do {
            let receipt = try await engine.update(id: reminder.id, title: title, dueAt: dueAt, notes: notes)
            if !receipt.notificationConfirmed { errorMessage = receipt.note }
            await reload()
        } catch let error as JarvisError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReminderRow: View {
    let reminder: Reminder
    let onComplete: () -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: JarvisTheme.Spacing.s) {
            HStack(alignment: .top, spacing: JarvisTheme.Spacing.s) {
                Button(action: onComplete) {
                    Image(systemName: reminder.completedAt == nil ? "circle" : "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(reminder.completedAt == nil ? JarvisTheme.Palette.ice : JarvisTheme.Palette.mint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reminder.completedAt == nil ? "Complete reminder" : "Completed")

                VStack(alignment: .leading, spacing: 3) {
                    Text(reminder.title)
                        .font(JarvisTheme.Typography.callout)
                        .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                        .strikethrough(reminder.completedAt != nil)
                    Text(reminder.describe())
                        .font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    if let notes = reminder.notes, !notes.isEmpty {
                        Text(notes).font(JarvisTheme.Typography.micro)
                            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    }
                    if reminder.notificationIdentifier == nil {
                        StatusPill(text: "no notification", systemImage: "bell.slash", tint: JarvisTheme.Palette.warning)
                    } else if reminder.recurrence != nil {
                        StatusPill(text: "repeats", systemImage: "repeat", tint: JarvisTheme.Palette.cyan)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: JarvisTheme.Spacing.s) {
                Button("Edit", action: onEdit).font(JarvisTheme.Typography.micro).foregroundStyle(JarvisTheme.Palette.ice)
                Button("Cancel", action: onCancel).font(JarvisTheme.Typography.micro).foregroundStyle(JarvisTheme.Palette.danger)
                Spacer(minLength: 0)
            }
        }
        .padding(JarvisTheme.Spacing.m)
        .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
        .accessibilityElement(children: .contain)
    }
}

private struct ReminderEditSheet: View {
    let reminder: Reminder
    let onSave: (String, Date, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var notes: String

    init(reminder: Reminder, onSave: @escaping (String, Date, String?) -> Void) {
        self.reminder = reminder
        self.onSave = onSave
        _title = State(initialValue: reminder.title)
        _date = State(initialValue: reminder.dueAt)
        _notes = State(initialValue: reminder.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    TextField("Title", text: $title)
                    DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                Section {
                    Label("Time zone: \(reminder.timeZoneIdentifier)", systemImage: "globe")
                        .font(JarvisTheme.Typography.caption)
                    if let recurrence = reminder.recurrence {
                        Label("Repeats: \(recurrence.describe())", systemImage: "repeat")
                            .font(JarvisTheme.Typography.caption)
                    }
                }
            }
            .navigationTitle("Edit reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title, date, notes.isEmpty ? nil : notes)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
