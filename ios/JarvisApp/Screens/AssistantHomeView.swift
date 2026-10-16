import SwiftUI

/// The main screen: orb, live state, transcript, composer, status rail.
public struct AssistantHomeView: View {

    @ObservedObject var model: AssistantViewModel
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var showsMemoryInspector = false
    @State private var showsHistory = false
    @State private var showsProviderSettings = false

    public init(model: AssistantViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                        orbSection
                        statusRail
                        ForEach(model.transcript) { item in
                            TranscriptRow(item: item).id(item.id)
                        }
                        if let error = model.lastError {
                            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.s) {
                                InlineBanner(kind: .error, title: "That didn't work", message: error)
                                if !environment.providerState.isUsable {
                                    GlassButton("Configure AI provider", systemImage: "key.fill", style: .secondary) {
                                        showsProviderSettings = true
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.horizontal, JarvisTheme.Spacing.m)
                    .padding(.top, JarvisTheme.Spacing.s)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.transcript.count) { _, _ in
                    withAnimation(JarvisTheme.Motion.gentle) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            composer
        }
        .sheet(isPresented: $showsMemoryInspector) {
            MemoryInspectorSheet(memories: model.memoriesUsed)
        }
        .sheet(isPresented: $showsHistory) {
            NavigationStack { ConversationHistoryView().environmentObject(environment) }
        }
        .sheet(isPresented: $showsProviderSettings) {
            NavigationStack { ProviderSettingsView().environmentObject(environment) }
        }
        .safeAreaInset(edge: .bottom) { confirmationCard }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: JarvisTheme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("JARVIS")
                    .font(JarvisTheme.Typography.micro)
                    .tracking(3)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                Text(model.state.label)
                    .font(JarvisTheme.Typography.title)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                if let detail = model.state.detail {
                    Text(detail)
                        .font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    Haptics.tap()
                    Task { await model.startNewConversation() }
                } label: {
                    Image(systemName: "plus.bubble").font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("New conversation")

                Button {
                    Haptics.tap()
                    showsHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("Conversation history")
            }
            .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.pill)
        }
        .padding(.horizontal, JarvisTheme.Spacing.m)
        .padding(.top, JarvisTheme.Spacing.s)
    }

    // MARK: Orb

    private var orbSection: some View {
        VStack(spacing: JarvisTheme.Spacing.m) {
            JarvisOrb(state: model.state, audioLevel: model.orbLevel,
                      size: 236)
                .padding(.top, JarvisTheme.Spacing.s)

            if model.isDictating || model.state == .speaking {
                AudioWaveformView(levels: model.waveformLevels,
                                  isActive: true,
                                  tint: model.state == .speaking ? JarvisTheme.Palette.silver : JarvisTheme.Palette.cyan)
                    .padding(.horizontal, JarvisTheme.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: Status rail

    private var statusRail: some View {
        HStack(spacing: JarvisTheme.Spacing.s) {
            MetricTile(label: "Memories", value: "\(model.memoryCount)")
            MetricTile(label: "Model",
                       value: providerLabel,
                       tint: environment.providerState.isUsable ? JarvisTheme.Palette.mint : JarvisTheme.Palette.amber)
            if !model.toolActivity.isEmpty {
                MetricTile(label: "Tools", value: "\(model.toolActivity.count)", tint: JarvisTheme.Palette.cyan)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var providerLabel: String {
        guard let settings = try? environment.providerSettings.settings() else { return "not set" }
        return ProviderCatalog.entry(id: settings.providerID)?.displayName ?? settings.providerID
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: JarvisTheme.Spacing.s) {
            if !model.memoriesUsed.isEmpty {
                Button {
                    showsMemoryInspector = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile").font(.system(size: 11, weight: .semibold))
                        Text("Using \(model.memoriesUsed.count) remembered detail\(model.memoriesUsed.count == 1 ? "" : "s")")
                            .font(JarvisTheme.Typography.micro)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(JarvisTheme.Palette.ice)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .bottom, spacing: JarvisTheme.Spacing.s) {
                Button {
                    Task { await model.toggleDictation() }
                } label: {
                    Image(systemName: model.isDictating ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(model.isDictating ? JarvisTheme.Palette.cyan : JarvisTheme.Palette.ice)
                        .symbolEffect(.pulse, isActive: model.isDictating)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isDictating ? "Stop dictation" : "Start dictation")

                TextField("Ask JARVIS…", text: $model.composerText, axis: .vertical)
                    .font(JarvisTheme.Typography.body)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await model.send() } }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: JarvisTheme.Radius.large, style: .continuous)
                            .fill(JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.65))
                    }
                    .accessibilityLabel("Message")

                if isWorking {
                    Button {
                        model.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(JarvisTheme.Palette.rose)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(model.composerText.trimmingCharacters(in: .whitespaces).isEmpty
                                             ? JarvisTheme.Palette.tertiaryText(scheme)
                                             : JarvisTheme.Palette.ice)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.composerText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, JarvisTheme.Spacing.m)
            .padding(.vertical, JarvisTheme.Spacing.s)
            .jarvisGlass(.strong, cornerRadius: JarvisTheme.Radius.large)

            HStack(spacing: JarvisTheme.Spacing.s) {
                Toggle(isOn: $model.speaksReplies) {
                    Label("Speak replies", systemImage: "speaker.wave.2.fill")
                        .font(JarvisTheme.Typography.micro)
                }
                .toggleStyle(.switch)
                .tint(JarvisTheme.Palette.ice)

                if environment.speechSynthesizer.isSpeaking {
                    Button("Stop speaking") { model.stopSpeaking() }
                        .font(JarvisTheme.Typography.micro)
                }
                Spacer(minLength: 0)
                Text(environment.capability(CapabilityID.voiceInput).isUsable ? "Voice ready" : "Voice needs permission")
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            }
            .padding(.horizontal, JarvisTheme.Spacing.s)
        }
        .padding(.horizontal, JarvisTheme.Spacing.m)
        .padding(.top, JarvisTheme.Spacing.s)
        .padding(.bottom, JarvisTheme.Spacing.m)
    }

    private var isWorking: Bool {
        switch model.state {
        case .thinking, .executing, .awaitingConfirmation: return true
        case .speaking, .listening, .idle, .failed: return false
        }
    }

    // MARK: Confirmation card (high-impact actions)

    @ViewBuilder
    private var confirmationCard: some View {
        if let pending = model.pendingConfirmation {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.s) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(JarvisTheme.Palette.amber)
                    Text("Confirm \(pending.toolName)").font(JarvisTheme.Typography.headline)
                        .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    Spacer()
                    StatusPill(text: pending.risk.rawValue, systemImage: "exclamationmark.shield.fill",
                               tint: pending.risk >= .communicating ? JarvisTheme.Palette.danger : JarvisTheme.Palette.warning)
                }
                Text(pending.prompt)
                    .font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                if let arguments = pending.arguments.objectValue, !arguments.isEmpty {
                    Text(prettyArguments(arguments))
                        .font(JarvisTheme.Typography.micro.monospaced())
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        .lineLimit(4)
                }
                HStack(spacing: JarvisTheme.Spacing.s) {
                    GlassButton("Approve", systemImage: "checkmark", style: .primary) { model.approveConfirmation() }
                    GlassButton("Decline", systemImage: "xmark", style: .secondary) { model.declineConfirmation() }
                }
            }
            .padding(JarvisTheme.Spacing.m)
            .jarvisGlass(.strong, cornerRadius: JarvisTheme.Radius.large, accent: JarvisTheme.Palette.amber)
            .padding(.horizontal, JarvisTheme.Spacing.m)
            .padding(.bottom, JarvisTheme.Spacing.s)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(reduceMotion ? nil : JarvisTheme.Motion.smooth, value: pending.id)
        }
    }

    private func prettyArguments(_ arguments: [String: JSONValue]) -> String {
        arguments.keys.sorted().map { key in
            let value = arguments[key]?.stringValue ?? arguments[key]?.jsonString ?? ""
            let truncated = value.count > 90 ? String(value.prefix(90)) + "…" : value
            return "\(key): \(truncated)"
        }.joined(separator: "  ·  ")
    }
}

// MARK: - Transcript row

struct TranscriptRow: View {
    let item: TranscriptItem
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: JarvisTheme.Spacing.xl)
                Text(item.text)
                    .font(JarvisTheme.Typography.body)
                    .foregroundStyle(JarvisTheme.Palette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: JarvisTheme.Radius.large, style: .continuous)
                            .fill(JarvisTheme.Palette.ice.opacity(0.92))
                    }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(item.text)")

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("JARVIS").font(JarvisTheme.Typography.micro).tracking(2)
                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    if item.isStreaming { LoadingDots() }
                }
                Text(item.text.isEmpty ? "…" : item.text)
                    .font(JarvisTheme.Typography.body)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = item.caption {
                    Text(caption).font(JarvisTheme.Typography.micro)
                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(JarvisTheme.Spacing.m)
            .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
            .accessibilityElement(children: .combine)

        case .tool:
            HStack(alignment: .top, spacing: JarvisTheme.Spacing.s) {
                Image(systemName: item.caption == "failed" ? "xmark.octagon" : "bolt.horizontal.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.caption == "failed" ? JarvisTheme.Palette.danger : JarvisTheme.Palette.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption = item.caption, caption != "failed" {
                        Text(caption == "verified" ? "verified by the service" : "reported by the tool")
                            .font(JarvisTheme.Typography.micro)
                            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

        case .system:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = item.caption {
                    Text(caption.uppercased()).font(JarvisTheme.Typography.micro).tracking(1)
                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                }
            }
            .padding(JarvisTheme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: JarvisTheme.Radius.small, style: .continuous)
                    .fill(JarvisTheme.Palette.glassTint.opacity(scheme == .dark ? 0.14 : 0.08))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Memory inspector

struct MemoryInspectorSheet: View {
    let memories: [ScoredMemory]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                    Text("These are the memories retrieved for your last message, ranked by relevance. Open the Memory tab to inspect, correct or delete any of them.")
                        .font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    ForEach(memories, id: \.record.id) { memory in
                        GlassCard(title: memory.record.kind.displayName,
                                  subtitle: "updated \(memory.record.updatedAt.relativeDescription())") {
                            Text(memory.record.text)
                                .font(JarvisTheme.Typography.body)
                                .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                            HStack(spacing: 6) {
                                StatusPill(text: "score \(String(format: "%.2f", memory.score))",
                                           systemImage: "target", tint: JarvisTheme.Palette.ice)
                                if memory.record.source.isUntrusted {
                                    StatusPill(text: "external", systemImage: "globe", tint: JarvisTheme.Palette.warning)
                                }
                                if memory.record.locked {
                                    StatusPill(text: "instruction", systemImage: "lock.fill", tint: JarvisTheme.Palette.cyan)
                                }
                            }
                        }
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
            .background(AmbientBackground())
            .navigationTitle("Memory used")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
