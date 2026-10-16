import SwiftUI

/// API & Provider configuration.
///
/// Honesty rules:
///  * the catalog lists what is free *today*, with the verification date;
///  * keys are stored in the Keychain, never in UserDefaults, logs or the repo;
///  * “Test connection” performs a real request and reports the real result.
public struct ProviderSettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var selectedID: String = ProviderCatalog.entries.first?.id ?? "groq"
    @State private var model: String = ""
    @State private var baseURLOverride: String = ""
    @State private var keyInput: String = ""
    @State private var hasStoredKey = false
    @State private var status: TestStatus = .idle
    @State private var isLoading = false

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
                    LoadingDots()
                } else {
                    providerPicker
                    if let entry = ProviderCatalog.entry(id: selectedID) {
                        providerDetails(entry)
                        keySection(entry)
                        modelSection(entry)
                    }
                    testSection
                    zeroCostNote
                }
            }
            .padding(JarvisTheme.Spacing.m)
        }
        .background(AmbientBackground())
        .navigationTitle("AI Providers")
        .task { await loadExisting() }
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
                        .padding(.vertical, 6)
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
                    SecureField(hasStoredKey ? "•••••••• (saved)" : "Paste your key", text: $keyInput)
                        .font(JarvisTheme.Typography.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: JarvisTheme.Radius.medium, style: .continuous)
                                .fill(JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.10 : 0.6))
                        }
                    GlassButton("Save", systemImage: "checkmark", style: .primary) { saveKey() }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: JarvisTheme.Spacing.s) {
                    if hasStoredKey {
                        StatusPill(text: "key saved", systemImage: "lock.fill", tint: JarvisTheme.Palette.mint)
                        GlassButton("Remove key", systemImage: "trash", style: .secondary) { removeKey() }
                    } else {
                        StatusPill(text: "no key", systemImage: "lock.open", tint: JarvisTheme.Palette.amber)
                    }
                }
                Text("The key is written straight to the Keychain. It is never logged, never shown again, and never leaves the device except in requests to the provider you chose.")
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            } else {
                Text("This provider runs on your own machine (for example Ollama at http://localhost:11434/v1). Start it before testing the connection. A phone cannot reach your Mac's localhost — use your computer's LAN address or a tunnel, and remember that Ollama must be reachable from the device.")
                    .font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
            }
        }
    }

    private func modelSection(_ entry: ProviderCatalogEntry) -> some View {
        GlassCard(title: "Model & endpoint", subtitle: "Defaults are the ones verified free on \(ProviderCatalog.verificationDate)") {
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
            GlassButton("Save configuration", systemImage: "square.and.arrow.down", style: .primary) { saveSettings() }
        }
    }

    private var testSection: some View {
        GlassCard(title: "Test connection", subtitle: "Sends one short real request — no token is spent beyond your free quota") {
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

    private var zeroCostNote: some View {
        GlassCard(title: "Zero-cost policy") {
            Text("""
            JARVIS never enables billing, never upgrades a plan and never asks for a payment method. \
            If a free tier is exhausted, the app reports the limit and stops — it does not silently fail over to a paid model. \
            Free tiers change without notice: verify the provider's current terms before relying on them, and see docs/FREE_TIER_POLICY.md.
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
        if let settings = try? environment.providerSettings.settings() {
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

    private func saveKey() {
        do {
            try environment.secrets.setSecret(keyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                              for: SecretKey.apiKey(for: selectedID))
            keyInput = ""
            hasStoredKey = true
            Haptics.success()
            environment.providerRegistry?.invalidate()
            status = .idle
        } catch let error as JarvisError {
            status = .failure(error.userMessage)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func removeKey() {
        try? environment.secrets.setSecret(nil, for: SecretKey.apiKey(for: selectedID))
        hasStoredKey = false
        environment.providerRegistry?.invalidate()
        Haptics.tap()
    }

    private func saveSettings() {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = ProviderSettings(
            providerID: selectedID,
            model: trimmedModel.isEmpty ? (ProviderCatalog.entry(id: selectedID)?.defaultModel ?? "") : trimmedModel,
            baseURLOverride: baseURLOverride.trimmingCharacters(in: .whitespaces).isEmpty ? nil : baseURLOverride.trimmingCharacters(in: .whitespaces)
        )
        do {
            try environment.providerSettings.save(settings)
            environment.providerRegistry?.invalidate()
            Haptics.success()
            Task { await environment.refreshCapabilities() }
        } catch let error as JarvisError {
            status = .failure(error.userMessage)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func runTest() async {
        status = .running
        saveSettingsIfNeeded()
        guard let provider = try? environment.providerRegistry?.activeProvider() ?? nil else {
            status = .failure("No provider is configured yet. Choose one, paste a key and save it first.")
            return
        }
        let request = ChatRequest(messages: [.user("Reply with the single word: ready")],
                                  temperature: 0, maxOutputTokens: 12)
        do {
            let response = try await provider.complete(request)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            status = .success("\(provider.displayName) answered “\(text.isEmpty ? "(empty)" : String(text.prefix(60)))” using \(response.model).")
            Haptics.success()
        } catch let error as JarvisError {
            status = .failure(error.userMessage)
            Haptics.error()
        } catch {
            status = .failure(error.localizedDescription)
            Haptics.error()
        }
        await environment.refreshCapabilities()
    }

    private func saveSettingsIfNeeded() {
        if (try? environment.providerSettings.settings()) == nil { saveSettings() }
    }
}
