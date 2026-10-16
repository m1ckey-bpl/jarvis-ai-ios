import SwiftUI

/// Error & Recovery. Shown when the app cannot start properly — the real error,
/// a plain-language explanation, and concrete next steps.
public struct RecoveryView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var copied = false

    public init() {}

    public var body: some View {
        ZStack {
            AmbientBackground(accent: JarvisTheme.Palette.rose, intensity: 0.5).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                    HStack(spacing: JarvisTheme.Spacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(JarvisTheme.Palette.rose)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("JARVIS could not start")
                                .font(JarvisTheme.Typography.title)
                                .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                            Text("Your data has not been modified.")
                                .font(JarvisTheme.Typography.caption)
                                .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        }
                    }

                    GlassCard(title: "What happened", subtitle: detailTitle) {
                        Text(detailMessage)
                            .font(JarvisTheme.Typography.caption)
                            .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    GlassCard(title: "What you can do") {
                        bullet("Force-quit and reopen JARVIS — a transient file lock is the most common cause.")
                        bullet("Check free storage: Settings ▸ General ▸ iPhone Storage. JARVIS needs room for its databases.")
                        bullet("If this persists, reinstall the app. Because data lives only on this device, reinstall clears it — export memories first if the app opens far enough to allow it.")
                        GlassButton(copied ? "Copied" : "Copy diagnostic text",
                                    systemImage: copied ? "checkmark" : "doc.on.doc",
                                    style: .secondary) { copyDiagnostics() }
                    }

                    GlassCard(title: "Diagnostics", subtitle: "No secrets are included") {
                        Text(diagnosticText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                            .textSelection(.enabled)
                    }
                }
                .padding(JarvisTheme.Spacing.m)
            }
        }
    }

    private var detailTitle: String {
        guard let error = environment.startupError else { return "Unknown error" }
        switch error {
        case .storage: return "Local storage"
        case .unexpected: return "Unexpected error"
        default: return "Startup error"
        }
    }

    private var detailMessage: String {
        guard let error = environment.startupError else { return "No error detail was recorded." }
        return error.userMessage
    }

    private var diagnosticText: String {
        var lines = [
            "JARVIS startup diagnostics",
            "time: \(Date().iso8601)",
            "system: \(environment.systemName) \(environment.systemVersion)",
            "timezone: \(TimeZone.current.identifier)",
            "locale: \(Locale.current.identifier)",
            "providerState: \(environment.providerState.label)",
            "error: \(environment.startupError?.userMessage ?? "none")"
        ]
        if let memory = environment.memory, let count = try? memory.count() {
            lines.append("memoryRecords: \(count)")
        }
        lines.append("toolLogAvailable: \(environment.toolLog != nil)")
        return lines.joined(separator: "\n")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6)
                .foregroundStyle(JarvisTheme.Palette.ice)
            Text(text).font(JarvisTheme.Typography.caption)
                .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyDiagnostics() {
        #if canImport(UIKit)
        UIPasteboard.general.string = diagnosticText
        #endif
        copied = true
        Haptics.success()
    }
}
