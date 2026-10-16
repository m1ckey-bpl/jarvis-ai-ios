import SwiftUI

/// Settings hub. Every row leads somewhere real, and states are read from the
/// live capability registry rather than hard-coded.
public struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var showsEraseConfirm = false
    @State private var eraseResult: String?
    @State private var showAdvanced = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                    SectionHeader("Assistant", subtitle: "What can run right now")
                    NavigationLink { ProviderSettingsView().environmentObject(environment) } label: {
                        settingRow(title: "AI Providers", subtitle: providerSubtitle,
                                   state: environment.providerState, systemImage: "cpu")
                    }
                    .buttonStyle(.plain)

                    NavigationLink { PermissionSetupView().environmentObject(environment) } label: {
                        settingRow(title: "Permissions & connections",
                                   subtitle: "Microphone, speech, notifications, calendar",
                                   state: permissionSummary, systemImage: "lock.shield")
                    }
                    .buttonStyle(.plain)

                    SectionHeader("Integrations", subtitle: "Official APIs only")
                    NavigationLink { ConnectedServicesView().environmentObject(environment) } label: {
                        settingRow(title: "Connected Services",
                                   subtitle: "\(readyIntegrations) of \(environment.capabilities.count) ready",
                                   state: readyIntegrations > 0 ? .ready : .requiresConfiguration(detail: "Nothing connected yet."),
                                   systemImage: "link")
                    }
                    .buttonStyle(.plain)

                    NavigationLink { ToolHistoryView().environmentObject(environment) } label: {
                        settingRow(title: "Tool execution history",
                                   subtitle: "What JARVIS ran, with redacted arguments",
                                   state: .ready, systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.plain)

                    SectionHeader("Data & privacy", subtitle: "Everything stays on this device unless you connect a service")
                    GlassCard(title: "Local storage",
                              subtitle: "Memory, conversations, reminders and tool logs live in this app's container.") {
                        Text("JARVIS sends your message — plus the memories it selected — to the AI provider you configured. Nothing else leaves the device. External documents (email, web pages, files) are treated as untrusted data and can never change JARVIS's rules.")
                            .font(JarvisTheme.Typography.caption)
                            .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        GlassButton("Erase all local data…", systemImage: "trash", style: .destructive) {
                            showsEraseConfirm = true
                        }
                        if let eraseResult {
                            Text(eraseResult).font(JarvisTheme.Typography.micro)
                                .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        }
                    }

                    SectionHeader("About")
                    GlassCard(title: "JARVIS",
                              subtitle: "Version \(environment.deviceInfo()["appVersion"] ?? "?") (\(environment.deviceInfo()["build"] ?? "?"))") {
                        LabeledContent("System", value: "\(environment.systemName) \(environment.systemVersion)")
                        LabeledContent("Time zone", value: TimeZone.current.identifier)
                        LabeledContent("Locale", value: Locale.current.identifier)
                        LabeledContent("Provider catalog verified", value: ProviderCatalog.verificationDate)
                        Text("Provider limits change. JARVIS shows the date these free-tier terms were last verified and links to the provider's own documentation.")
                            .font(JarvisTheme.Typography.micro)
                            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    }

                    GlassCard(title: "Companion backend", subtitle: "Optional") {
                        Text("JARVIS works fully on-device. A backend adds server-side OAuth exchange, background scheduling and webhooks. Until one is deployed and configured, those specific tools report “backend needed” instead of pretending to work.")
                            .font(JarvisTheme.Typography.caption)
                            .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        HStack(spacing: 6) { StatusPill.forCapability(environment.capability(CapabilityID.backend)) }
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
            .background(AmbientBackground())
            .navigationTitle("Settings")
            .confirmationDialog("Erase all local data?",
                                isPresented: $showsEraseConfirm, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) { Task { await erase() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes memories, conversations, reminders, tool logs and saved keys from this device. It cannot be undone.")
            }
        }
    }

    private var providerSubtitle: String {
        guard let settings = try? environment.providerSettings.settings() else { return "Not configured" }
        let name = ProviderCatalog.entry(id: settings.providerID)?.displayName ?? settings.providerID
        return "\(name) · \(settings.model)"
    }

    private var readyIntegrations: Int {
        environment.capabilities.filter { $0.state.isUsable }.count
    }

    private var permissionSummary: CapabilityState {
        let needed = [CapabilityID.voiceInput, CapabilityID.reminders, CapabilityID.appleCalendar]
            .map { environment.capability($0) }
        return needed.first(where: { !$0.isUsable }) ?? .ready
    }

    private func settingRow(title: String, subtitle: String, state: CapabilityState, systemImage: String) -> some View {
        HStack(spacing: JarvisTheme.Spacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(JarvisTheme.Palette.ice)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(JarvisTheme.Typography.callout)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                Text(subtitle).font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            StatusPill.forCapability(state)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
        }
        .padding(JarvisTheme.Spacing.m)
        .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
    }

    private func erase() async {
        do {
            try await environment.eraseAllLocalData()
            await environment.refreshCapabilities()
            eraseResult = "All local data erased."
            Haptics.success()
        } catch {
            eraseResult = "Erase failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }
}
