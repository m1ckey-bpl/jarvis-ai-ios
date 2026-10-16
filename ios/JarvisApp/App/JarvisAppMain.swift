import SwiftUI

@main
struct JarvisAppMain: App {
    @StateObject private var environment = AppEnvironment()
    @State private var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "ai.jarvis.onboarded")

    var body: some Scene {
        WindowGroup {
            Group {
                if environment.startupError != nil {
                    RecoveryView()
                } else if !hasCompletedOnboarding {
                    OnboardingView(onFinish: {
                        UserDefaults.standard.set(true, forKey: "ai.jarvis.onboarded")
                        hasCompletedOnboarding = true
                    })
                } else {
                    NavigationShell()
                }
            }
            .environmentObject(environment)
            .tint(JarvisTheme.Palette.ice)
            .preferredColorScheme(nil)          // honour the system appearance
            .task { await environment.refreshCapabilities() }
        }
    }
}
