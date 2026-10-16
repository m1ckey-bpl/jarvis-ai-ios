import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Permission & connection setup. Requests are made only when the user taps, and
/// each row reports what iOS actually decided.
public struct PermissionSetupView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var message: String?
    @State private var messageIsError = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                GlassCard(title: "Why JARVIS asks",
                          subtitle: "Nothing is requested until you tap") {
                    Text("JARVIS asks only for what a feature you enabled needs. Refusing a permission never breaks the rest of the app — the affected feature reports that it is unavailable instead of failing silently.")
                        .font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                }

                SectionHeader("On-device permissions")
                row(title: "Microphone & speech",
                    subtitle: "Needed for voice input. Audio is transcribed on device when the device supports it.",
                    state: environment.capability(CapabilityID.voiceInput),
                    actionTitle: "Request") {
                    Task {
                        let state = await environment.speechRecognizer.requestPermissions()
                        report(state, label: "Voice input")
                    }
                }

                row(title: "Notifications",
                    subtitle: "Needed for reminders. Reminders still save locally if notifications are off.",
                    state: environment.capability(CapabilityID.reminders),
                    actionTitle: "Request") {
                    Task {
                        let state = await environment.reminderEngine?.requestAuthorization() ?? .unavailable(reason: "Reminders are not initialised.")
                        report(state, label: "Notifications")
                    }
                }

                row(title: "Calendar & Reminders (EventKit)",
                    subtitle: "Read your schedule and create events you ask for. Write access is requested only for events JARVIS creates.",
                    state: environment.capability(CapabilityID.appleCalendar),
                    actionTitle: "Request") {
                    Task { report(await environment.calendar.requestAccess(), label: "Calendar") }
                }

                SectionHeader("Credentials")
                row(title: "AI provider key",
                    subtitle: "Stored in the iOS Keychain, scoped to this device.",
                    state: environment.providerState,
                    actionTitle: "Open provider settings") { }

                row(title: "GitHub",
                    subtitle: "Personal access token (read:user, repo) or OAuth device flow.",
                    state: environment.capability(CapabilityID.github),
                    actionTitle: "Add token") { }

                row(title: "Google / Gmail",
                    subtitle: "Google OAuth with PKCE. Server-side exchange is recommended, so the client secret never ships in the app.",
                    state: environment.capability(CapabilityID.gmail),
                    actionTitle: "Configure") { }

                row(title: "Instagram",
                    subtitle: "Meta Graph API for professional accounts only. Personal accounts have no official messaging API — JARVIS will not pretend otherwise.",
                    state: environment.capability(CapabilityID.instagram),
                    actionTitle: "Configure") { }

                if let message {
                    InlineBanner(kind: messageIsError ? .error : .success,
                                 title: messageIsError ? "Not granted" : "Done",
                                 message: message)
                }

                GlassCard(title: "System settings") {
                    Text("If iOS has recorded a refusal, only you can change it — apps cannot ask twice.")
                        .font(JarvisTheme.Typography.micro)
                        .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    GlassButton("Open iOS Settings for JARVIS", systemImage: "gear", style: .secondary, action: openSystemSettings)
                }
            }
            .padding(JarvisTheme.Spacing.m)
        }
        .background(AmbientBackground())
        .navigationTitle("Permissions")
        .task { await environment.refreshCapabilities() }
    }

    private func row(title: String, subtitle: String, state: CapabilityState,
                     actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: JarvisTheme.Spacing.s) {
            HStack(spacing: JarvisTheme.Spacing.s) {
                Text(title).font(JarvisTheme.Typography.callout)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                Spacer(minLength: 0)
                StatusPill.forCapability(state)
            }
            Text(state.isUsable ? subtitle : state.explanation)
                .font(JarvisTheme.Typography.caption)
                .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)
            if !state.isUsable {
                GlassButton(actionTitle, style: .secondary, action: action)
            }
        }
        .padding(JarvisTheme.Spacing.m)
        .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
    }

    private func report(_ state: CapabilityState, label: String) {
        messageIsError = !state.isUsable
        message = state.isUsable ? "\(label) is ready." : "\(label): \(state.explanation)"
        if state.isUsable { Haptics.success() } else { Haptics.warning() }
        Task { await environment.refreshCapabilities() }
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
