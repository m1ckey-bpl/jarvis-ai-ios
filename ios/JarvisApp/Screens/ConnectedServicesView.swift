import SwiftUI

/// Connected Services: every integration, its real state, and what it can and
/// cannot do through official APIs only.
public struct ConnectedServicesView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var message: String?
    @State private var showsSetup = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                    GlassCard(title: "Official channels only", subtitle: "No fake connectors") {
                        Text("""
                        JARVIS integrates exclusively through documented provider APIs and OS frameworks. \
                        Where a provider offers no official API for an action, JARVIS says so instead of imitating it:
                        • Gmail — Google OAuth, read/draft/send with your consent
                        • Instagram — Meta Graph API, professional accounts only
                        • WhatsApp — official deep-link composition, and the WhatsApp Business Platform from a backend
                        • GitHub — REST API with a personal access token or OAuth device flow
                        • Apple Calendar & Reminders — EventKit, on device
                        """)
                        .font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    SectionHeader("Services", subtitle: "\(environment.capabilities.filter { $0.state.isUsable }.count) of \(environment.capabilities.count) ready")

                    ForEach(environment.capabilities) { capability in
                        CapabilityRow(title: capability.name,
                                      subtitle: capability.summary,
                                      state: capability.state,
                                      actionTitle: actionTitle(for: capability.id),
                                      action: { perform(capability.id) })
                    }

                    if let message {
                        InlineBanner(kind: .info, title: "Next step", message: message)
                    }

                    GlassCard(title: "Adding credentials") {
                        Text("Provider tokens are stored in the iOS Keychain and used only for requests to that provider. A companion backend holds nothing unless you deploy it (docs/BUILD_GUIDE.md covers the optional server).")
                            .font(JarvisTheme.Typography.micro)
                            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        GlassButton("Open permission & connection setup", systemImage: "lock.shield", style: .secondary) {
                            showsSetup = true
                        }
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
            .background(AmbientBackground())
            .navigationTitle("Services")
            .sheet(isPresented: $showsSetup) {
                NavigationStack { PermissionSetupView().environmentObject(environment) }
            }
            .task { await environment.refreshCapabilities() }
        }
    }

    private func actionTitle(for id: String) -> String? {
        switch id {
        case CapabilityID.appleCalendar: return "Grant access"
        case CapabilityID.reminders: return "Allow notifications"
        case CapabilityID.voiceInput: return "Allow microphone"
        case CapabilityID.backend: return "How to deploy"
        default: return "Configure"
        }
    }

    private func perform(_ id: String) {
        switch id {
        case CapabilityID.appleCalendar:
            Task {
                let state = await environment.calendar.requestAccess()
                message = state.isUsable ? "Calendar access granted." : state.explanation
                await environment.refreshCapabilities()
            }
        case CapabilityID.reminders:
            Task {
                let state = await environment.reminderEngine?.requestAuthorization()
                message = state?.isUsable == true ? "Notifications allowed." : (state?.explanation ?? "Reminders are unavailable.")
                await environment.refreshCapabilities()
            }
        case CapabilityID.voiceInput:
            Task {
                let state = await environment.speechRecognizer.requestPermissions()
                message = state.isUsable ? "Voice input is ready." : state.explanation
                await environment.refreshCapabilities()
            }
        case CapabilityID.backend:
            message = "Deploy backend/ with your own free-tier host (see docs/BUILD_GUIDE.md and docs/FREE_TIER_POLICY.md), then paste its URL and token in Permission & connection setup. Until then, server-dependent tools report “backend needed”."
        default:
            showsSetup = true
        }
    }
}
