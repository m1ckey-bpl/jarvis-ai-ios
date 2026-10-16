import SwiftUI

@main
struct JarvisAppMain: App {
    @StateObject private var environment = AppEnvironment()
    @StateObject private var parallax = MotionParallax()
    @Environment(\.scenePhase) private var scenePhase
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
            .environmentObject(parallax)
            .tint(JarvisTheme.Palette.ice)
            .preferredColorScheme(nil)          // honour the system appearance
            .task { await environment.refreshCapabilities() }
            .onChange(of: scenePhase) { _, phase in
                // Stop the motion sensor when the app is not in front: no battery drain
                // for an animation nobody can see.
                switch phase {
                case .active: parallax.start()
                case .background, .inactive: parallax.stop()
                @unknown default: break
                }
            }
        }
    }
}
