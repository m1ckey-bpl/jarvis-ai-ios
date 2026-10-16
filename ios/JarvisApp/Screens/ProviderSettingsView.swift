import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// API & Provider configuration.
///
/// What went wrong in the first device build, and what this screen does about it:
///
/// * Saving a key stored the key for the *selected* provider but never persisted which
///   provider was selected. With no saved `ProviderSettings`, the assistant reported
///   "I can't reach a language model yet — Open Settings ▸ AI Providers" no matter how
///   many times the key was saved. Now every save (key or configuration) writes
///   provider + model + endpoint **and** marks it active, so what you see here is what
///   the assistant will use on the next turn.
/// * Selecting Gemini, pasting a Gemini key and pressing "Run test" sent that key to
///   whichever provider had been saved earlier — Groq answered `401 Invalid API Key`,
///   which looks like a broken app. Tests now always activate the configuration on
///   screen first.
/// * Model names are no longer trusted from a hard-coded list: "List models" asks the
///   provider what *your* key can use and shows the real HTTP status when it refuses.
public struct ProviderSettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var selectedID: String = ProviderCatalog.entries.first?.id ?? "groq"
    @State private var model: String = ""
    @State private var baseURLOverride: String = ""
    @State private var keyInput: String = ""
    @State private var hasStoredKey = false
    @State private var status: TestStatus = .idle
    @State private var isLoading = true

    // Live model discovery
    @State private var discovered: [DiscoveredModel] = []
    @State private var discoveryNote: String?
    @State private var isDiscovering = false

    // Diagnostics of the last failure (shown to the user, copyable, never contains a key)
    @State private var diagnostics: ProviderDiagnostics?

    enum TestStatus: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                if isLoading {
                    HStack(spacing: JarvisTheme.Spacing.s) { LoadingDots(); Text("Reading saved configuration…").font(JarvisTheme.Typography.caption) }
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                } else {
                    activeProviderCard
                    providerPicker
                    if let entry = ProviderCatalog.entry(id: selectedID) {
                        providerDetails(entry)
                        keySection(entry)
                        modelSection(entry)
                    }
                    testSection
                    if diagnostics != nil { diagnosticsSection }
                    zeroCostNote
                }
            }
            .padding(JarvisTheme.Spacing.m)
            .padding(.bottom, JarvisTheme.Spacing.xl)
        }
        .background(AmbientBackground())
        .navigationTitle("AI Providers")
        .task { await loadExisting() }
    }

    // MARK: What the assistant will actually use

    @ViewBuilder
    private var activeProviderCard: some View {
        let saved = (try? environment.providerSettings.settings()) ?? nil
        GlassCard(title: "Active provider",
                  subtitle: "This is what the assistant uses on your next message",
                  accent: saved == nil ? JarvisTheme.Palette.amber : JarvisTheme.Palette.mint) {
            if let saved {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: JarvisTheme.Spacing.s) {
                        StatusPill(text: saved.providerID, systemImage: "checkmark.seal.fill", tint: JarvisTheme.Palette.mint)
                        Text(saved.model).font(JarvisTheme.Typography.timer)
                            .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    }
                    Text(providerStatusLine(saved))
                        .font(JarvisTheme.Typography.micro)
                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if saved.providerID != selectedID {
                    InlineBanner(kind: .warning, title: "You are editing a different provider",
                                 message: "\(saved.providerID) is active until you save \(selectedID).")
                }
            } else {
                Text("Nothing is saved yet, so the assistant cannot reach a model. Choose a provider, paste a free key and press “Save key and activate”.")
                    .font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerStatusLine(_ settings: ProviderSettings) -> String {
        let stored = (try? environment.secrets.secret(for: SecretKey.apiKey(for: settings.providerID))) ?? nil
        let fingerprint = ProviderModelDiscovery.fingerprint(of: stored ?? "")
        return "key: \(fingerprint) · endpoint: \(settings.baseURLOverride ?? ProviderCatalog.entry(id: settings.providerID)?.baseURL ?? "n/a")"
    }

    // MARK: Sections

    private var providerPicker: some View {
        GlassCard(title: "Provider", subtitle: "All options below have a free tier that does not require a credit card") {
            VStack(spacing: JarvisTheme.Spacing.xs) {
                ForEach(ProviderCatalog.entries) { entry in
                    Button {
                        Haptics.selection()
                        selectedID = entry.id
                        model = entry.defaultModel
                        keyInput = ""
                        status = .idle
                        discovered = []
                        discoveryNote = nil
                        diagnostics = nil
                        Task { await refreshStoredKey() }
                    } label: {
                        HStack(spacing: JarvisTheme.Spacing.s) {
                            Image(systemName: entry.kind == .gemini ? "sparkle" : "bolt.horizontal.circle")
                                .foregroundStyle(JarvisTheme.Palette.ice)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName).font(JarvisTheme.Typography.callout)
                                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                                Text(entry.defaultModel).font(JarvisTheme.Typography.micro)
                                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                            }
                            Spacer(minLength: 0)
                            if entry.requiresKey {
                                StatusPill(text: "key", systemImage: "key.fill", tint: JarvisTheme.Palette.silver)
                            } else {
                                StatusPill(text: "local", systemImage: "desktopcomputer", tint: JarvisTheme.Palette.mint)
                            }
                            if selectedID == entry.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(JarvisTheme.Palette.ice)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func providerDetails(_ entry: ProviderCatalogEntry) -> some View {
        GlassCard(title: entry.displayName, subtitle: entry.hasFreeTier ? "Free tier" : "Paid only") {
            Text(entry.freeTierNote)
                .font(JarvisTheme.Typography.caption)
                .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.keyInstructions)
                .font(JarvisTheme.Typography.micro)
                .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: entry.signupURL) {
                Link(destination: url) {
                    Label("Open \(entry.displayName) to get a free key", systemImage: "arrow.up.right.square")
                        .font(JarvisTheme.Typography.caption)
                }
                .tint(JarvisTheme.Palette.ice)
            }
            HStack(spacing: 6) {
                StatusPill(text: "base URL", systemImage: "network", tint: JarvisTheme.Palette.silver)
                Text(entry.baseURL).font(JarvisTheme.Typography.micro).lineLimit(1)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            }
        }
    }

    private func keySection(_ entry: ProviderCatalogEntry) -> some View {
        GlassCard(title: "API key", subtitle: entry.requiresKey ? "Stored in the iOS Keychain on this device only" : "Not required for this provider") {
            if entry.requiresKey {
                HStack(spacing: JarvisTheme.Spacing.s) {
                    SecureField(hasStoredKey ? "•••••••• (saved — paste a new one to replace it)" : "Paste your key", text: $keyInput)
                        .font(JarvisTheme.Typography.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: JarvisTheme.Radius.medium, style: .continuous)
                                .fill(JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
                        }
                }
                HStack(spacing: JarvisTheme.Spacing.s) {
                    GlassButton("Save key and activate", systemImage: "checkmark.seal",
                                style: .primary,
                                isEnabled: !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                disabledReason: "Paste a key first") {
                        saveKeyAndActivate()
                    }
                }
                HStack(spacing: JarvisTheme.Spacing.s) {
                    if hasStoredKey {
                        StatusPill(text: "key saved", systemImage: "lock.fill", tint: JarvisTheme.Palette.mint)
                        GlassButton("Remove key", systemImage: "trash", style: .secondary) { removeKey() }
                    } else {
                        StatusPill(text: "no key", systemImage: "lock.open", tint: JarvisTheme.Palette.amber)
                    }
                }
                Text("Saving the key also saves “\(entry.displayName)” as your active provider — the assistant then uses it immediately. The key is written straight to the Keychain: never logged, never shown again, and never sent anywhere except the provider you chose.")
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This provider runs on your own machine (for example Ollama at http://localhost:11434/v1). Start it before testing. A phone cannot reach your Mac's localhost — use the computer's LAN address or a tunnel.")
                    .font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                GlassButton("Save configuration and activate", systemImage: "square.and.arrow.down", style: .primary) {
                    activateFromForm(reason: "Configuration saved")
                }
            }
        }
    }

    private func modelSection(_ entry: ProviderCatalogEntry) -> some View {
        GlassCard(title: "Model & endpoint", subtitle: "Hard-coded defaults are only a starting point — ask your key what it can use") {
            HStack(spacing: JarvisTheme.Spacing.s) {
                Text("Model").font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                TextField(entry.defaultModel, text: $model)
                    .font(JarvisTheme.Typography.timer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use default") { model = entry.defaultModel }
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.ice)
            }
            if entry.kind == .openAICompatible {
                HStack(spacing: JarvisTheme.Spacing.s) {
                    Text("Endpoint").font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    TextField(entry.baseURL, text: $baseURLOverride)
                        .font(JarvisTheme.Typography.timer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            HStack(spacing: JarvisTheme.Spacing.s) {
                GlassButton("List models", systemImage: "list.bullet.rectangle", style: .secondary) {
                    Task { await discoverModels() }
                }
                GlassButton("Save and activate", systemImage: "square.and.arrow.down", style: .primary) {
                    activateFromForm(reason: "Saved")
                }
            }

            if isDiscovering {
                HStack(spacing: 8) { LoadingDots(); Text("Asking \(entry.displayName)…").font(JarvisTheme.Typography.micro) }
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
            }

            if let discoveryNote {
                Text(discoveryNote)
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !discovered.isEmpty {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.xs) {
                    Text("Available to your key").font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    ForEach(discovered) { option in
                        Button {
                            Haptics.selection()
                            model = option.id
                            status = .idle
                        } label: {
                            HStack(spacing: JarvisTheme.Spacing.s) {
                                Image(systemName: model == option.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(model == option.id ? JarvisTheme.Palette.ice : JarvisTheme.Palette.tertiaryText(scheme))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.displayName).font(JarvisTheme.Typography.callout)
                                        .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                                    if option.displayName != option.id {
                                        Text(option.id).font(JarvisTheme.Typography.micro)
                                            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Choose one, then press “Save and activate”. Names marked preview are experiments and may change without notice.")
                        .font(JarvisTheme.Typography.micro)
                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                }
            }
        }
    }

    private var testSection: some View {
        GlassCard(title: "Test connection", subtitle: "Saves what is on screen, then sends one short real request") {
            GlassButton("Run test", systemImage: "waveform.path.ecg", style: .primary) {
                Task { await runTest() }
            }
            switch status {
            case .idle:
                Text("Not tested yet in this session.")
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            case .running:
                HStack(spacing: 8) { LoadingDots(); Text("Contacting the provider…").font(JarvisTheme.Typography.micro) }
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
            case .success(let message):
                InlineBanner(kind: .success, title: "Connected", message: message)
            case .failure(let message):
                InlineBanner(kind: .error, title: "Not connected", message: message)
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if let diagnostics {
            GlassCard(title: "Diagnostics", subtitle: "Safe to share — the key itself is never included") {
                Text(diagnostics.report())
                    .font(JarvisTheme.Typography.micro.monospaced())
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: JarvisTheme.Spacing.s) {
                    #if canImport(UIKit)
                    GlassButton("Copy", systemImage: "doc.on.doc", style: .secondary) {
                        UIPasteboard.general.string = diagnostics.report()
                        Haptics.success()
                    }
                    #endif
                    ShareLink(item: diagnostics.report()) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(JarvisTheme.Typography.caption)
                    }
                    .tint(JarvisTheme.Palette.ice)
                }
            }
        }
    }

    private var zeroCostNote: some View {
        GlassCard(title: "Zero-cost policy") {
            Text("""
            JARVIS never enables billing, never upgrades a plan and never asks for a payment method. \
            If a free tier is exhausted, the app reports the limit and stops — it does not silently fail over to a paid model. \
            Free tiers change without notice: use “List models” to see what your key really has, and see docs/FREE_TIER_POLICY.md.
            """)
            .font(JarvisTheme.Typography.micro)
            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func loadExisting() async {
        isLoading = true
        defer { isLoading = false }
        let saved = (try? environment.providerSettings.settings()) ?? nil
        if let settings = saved {
            selectedID = settings.providerID
            model = settings.model
            baseURLOverride = settings.baseURLOverride ?? ""
        } else if let first = ProviderCatalog.entries.first {
            selectedID = first.id
            model = first.defaultModel
        }
        await refreshStoredKey()
    }

    private func refreshStoredKey() async {
        hasStoredKey = ((try? environment.secrets.secret(for: SecretKey.apiKey(for: selectedID))) ?? nil)?.isEmpty == false
    }

    /// The fix for the original bug: a key is only useful once the provider it belongs to
    /// is saved as the active provider.
    private func saveKeyAndActivate() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try environment.secrets.setSecret(key, for: SecretKey.apiKey(for: selectedID))
            keyInput = ""
            hasStoredKey = true
            environment.providerRegistry?.invalidate()
            activateFromForm(reason: "Key saved and “\(ProviderCatalog.entry(id: selectedID)?.displayName ?? selectedID)” is now the active provider")
            Task { await discoverModels() }        // show what this key can actually use
        } catch let error as JarvisError {
            status = .failure(error.userMessage)
            Haptics.error()
        } catch {
            status = .failure(error.localizedDescription)
            Haptics.error()
        }
    }

    private func removeKey() {
        try? environment.secrets.setSecret(nil, for: SecretKey.apiKey(for: selectedID))
        hasStoredKey = false
        environment.providerRegistry?.invalidate()
        discovered = []
        discoveryNote = nil
        Haptics.tap()
        Task { await environment.refreshCapabilities() }
    }

    /// Writes the form to the settings store and marks it active. Always saves — the old
    /// "save only if nothing is saved yet" shortcut is what sent a Gemini key to Groq.
    @discardableResult
    private func activateFromForm(reason: String?) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.isEmpty
            ? (ProviderCatalog.entry(id: selectedID)?.defaultModel ?? "")
            : trimmedModel
        let trimmedBase = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = ProviderSettings(
            providerID: selectedID,
            model: resolvedModel,
            baseURLOverride: trimmedBase.isEmpty ? nil : trimmedBase
        )
        do {
            try environment.providerSettings.save(settings)
            model = resolvedModel
            environment.providerRegistry?.invalidate()
            Haptics.success()
            if let reason { status = .success(reason) }
            Task { await environment.refreshCapabilities() }
            return true
        } catch let error as JarvisError {
            status = .failure(error.userMessage)
            Haptics.error()
            return false
        } catch {
            status = .failure(error.localizedDescription)
            Haptics.error()
            return false
        }
    }

    /// Asks the provider which chat models this key can use, and reports exactly what the
    /// provider said when it refuses.
    private func discoverModels() async {
        guard let entry = ProviderCatalog.entry(id: selectedID) else { return }
        let key = ((try? environment.secrets.secret(for: SecretKey.apiKey(for: selectedID))) ?? nil) ?? ""
        if entry.requiresKey, key.isEmpty {
            discoveryNote = "Save a key first — listing models needs one."
            return
        }
        isDiscovering = true
        diagnostics = nil
        defer { isDiscovering = false }

        let outcome = await ProviderModelDiscovery.probe(
            entry: entry, apiKey: key,
            baseURL: entry.kind == .openAICompatible ? (baseURLOverride.isEmpty ? nil : baseURLOverride) : nil,
            transport: environment.httpTransport
        )

        if let error = outcome.error {
            discovered = []
            let path = entry.kind == .gemini ? "/v1beta/models" : "/models"
            discoveryNote = "Listing failed: \(error.userMessage)"
            diagnostics = ProviderDiagnostics(
                providerName: entry.displayName, providerID: entry.id, model: model,
                endpointHost: ProviderModelDiscovery.endpointHost(of: baseURLOverride.isEmpty ? entry.baseURL : baseURLOverride),
                requestPath: ProviderModelDiscovery.redactedPath(path),
                keyFingerprint: ProviderModelDiscovery.fingerprint(of: key),
                httpStatus: outcome.httpStatus,
                providerMessage: outcome.providerMessage,
                outcome: error.userMessage
            )
            status = .failure(error.userMessage)
            Haptics.error()
            return
        }

        discovered = outcome.models
        if outcome.models.isEmpty {
            discoveryNote = "The provider answered but listed no chat models for this key. Paste a model name manually."
        } else {
            discoveryNote = "\(outcome.models.count) chat model\(outcome.models.count == 1 ? "" : "s") available to this key."
            if !outcome.models.contains(where: { $0.id == model }) {
                discoveryNote? += " Your current choice “\(model)” is not in the list."
            }
        }
        Haptics.success()
    }

    /// Saves the on-screen configuration first, so the test exercises exactly what the
    /// assistant will use — not whatever happened to be saved before.
    private func runTest() async {
        status = .running
        diagnostics = nil
        guard activateFromForm(reason: nil) else { return }
        guard let entry = ProviderCatalog.entry(id: selectedID) else { return }
        guard let provider = (try? environment.providerRegistry?.activeProvider()) ?? nil else {
            let message = entry.requiresKey
                ? "No active provider. Paste a key and press “Save key and activate” first."
                : "No active provider. Save the configuration first."
            status = .failure(message)
            return
        }

        let started = Date()
        let request = ChatRequest(messages: [.user("Reply with the single word: ready")],
                                  temperature: 0, maxOutputTokens: 12)
        do {
            let response = try await provider.complete(request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            status = .success("\(provider.displayName) answered “\(text.isEmpty ? "(empty)" : String(text.prefix(60)))” using \(response.model) in \(elapsed) ms.")
            Haptics.success()
        } catch let error as JarvisError {
            status = .failure(error.userMessage)
            recordDiagnostics(entry: entry, error: error)
            Haptics.error()
        } catch {
            status = .failure(error.localizedDescription)
            recordDiagnostics(entry: entry, error: .unexpected(error.localizedDescription))
            Haptics.error()
        }
        await environment.refreshCapabilities()
    }

    private func recordDiagnostics(entry: ProviderCatalogEntry, error: JarvisError) {
        let key = ((try? environment.secrets.secret(for: SecretKey.apiKey(for: entry.id))) ?? nil) ?? ""
        let path = entry.kind == .gemini
            ? "/v1beta/models/\(model):generateContent"
            : "/chat/completions"
        diagnostics = ProviderDiagnostics(
            providerName: entry.displayName, providerID: entry.id, model: model,
            endpointHost: ProviderModelDiscovery.endpointHost(of: baseURLOverride.isEmpty ? entry.baseURL : baseURLOverride),
            requestPath: path,
            keyFingerprint: ProviderModelDiscovery.fingerprint(of: key),
            httpStatus: nil,
            providerMessage: nil,
            outcome: error.userMessage
        )
    }
}
