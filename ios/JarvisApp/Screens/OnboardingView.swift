import SwiftUI

/// First run: what JARVIS is, what it can honestly do today, and the two choices
/// that matter (memory, and which free provider to use).
public struct OnboardingView: View {

    public var onFinish: () -> Void

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var scheme

    @State private var page = 0
    @State private var remembersByDefault = true

    public init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    public var body: some View {
        ZStack {
            AmbientBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    capability.tag(1)
                    memoryChoice.tag(2)
                    providerStep.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? JarvisTheme.Palette.ice : JarvisTheme.Palette.tertiaryText(scheme).opacity(0.4))
                            .frame(width: index == page ? 22 : 7, height: 7)
                            .animation(JarvisTheme.Motion.snappy, value: page)
                    }
                }
                .padding(.vertical, JarvisTheme.Spacing.s)

                HStack(spacing: JarvisTheme.Spacing.s) {
                    if page > 0 {
                        GlassButton("Back", style: .secondary) { withAnimation { page -= 1 } }
                    }
                    GlassButton(page == 3 ? "Start" : "Continue",
                                systemImage: page == 3 ? "sparkles" : "arrow.right",
                                style: .primary) {
                        if page == 3 {
                            UserDefaults.standard.set(remembersByDefault, forKey: "ai.jarvis.autoRemember")
                            finish()
                        } else {
                            withAnimation(JarvisTheme.Motion.snappy) { page += 1 }
                        }
                    }
                }
                .padding(.horizontal, JarvisTheme.Spacing.m)
                .padding(.bottom, JarvisTheme.Spacing.m)
            }
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: JarvisTheme.Spacing.l) {
            Spacer()
            JarvisOrb(state: .idle, audioLevel: 0, size: 190)
            VStack(spacing: JarvisTheme.Spacing.s) {
                Text("JARVIS")
                    .font(JarvisTheme.Typography.display)
                    .tracking(6)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                Text("An assistant that runs on your phone, keeps your memory on-device, and tells you the truth about what it can do.")
                    .font(JarvisTheme.Typography.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    .padding(.horizontal, JarvisTheme.Spacing.l)
            }
            Spacer()
        }
    }

    private var capability: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                Text("What works without any setup")
                    .font(JarvisTheme.Typography.title)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                bullet("Memory — “remember that I prefer concise answers”, then ask what JARVIS knows at any time.")
                bullet("Reminders — time-zone aware local notifications, one-off or repeating.")
                bullet("On-device actions — clock, device info, calendar (with permission), WhatsApp drafts.")
                Text("What needs a free key")
                    .font(JarvisTheme.Typography.title)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                bullet("Conversation with a language model, via a provider with a genuinely free tier (Groq or Google AI Studio). JARVIS never enables billing and never silently switches to a paid model.")
                Text("What needs your own accounts")
                    .font(JarvisTheme.Typography.title)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                bullet("GitHub, Gmail and Instagram use each provider's official API and your credentials. Where an official API does not exist for an action, JARVIS says so.")
            }
            .padding(JarvisTheme.Spacing.m)
        }
    }

    private var memoryChoice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                Text("Memory stays on this device")
                    .font(JarvisTheme.Typography.title)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                Text("JARVIS stores memories in a local database. When you send a message, it retrieves the few memories that matter and includes them in the request to your provider — nothing is uploaded to any server of ours, because there isn't one.")
                    .font(JarvisTheme.Typography.body)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                Toggle(isOn: $remembersByDefault) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember useful details automatically").font(JarvisTheme.Typography.callout)
                        Text("Facts, preferences and instructions you state directly. Never guesses, never questions.")
                            .font(JarvisTheme.Typography.micro)
                            .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                    }
                }
                .tint(JarvisTheme.Palette.ice)
                GlassCard(title: "You stay in control") {
                    bullet("Say “forget …” to remove something, or use the Memory tab to correct or delete any record.")
                    bullet("Explicit instructions outrank anything JARVIS inferred, and content from email or the web can never change its rules.")
                    bullet("Export everything as JSON, Markdown or CSV whenever you want.")
                }
            }
            .padding(JarvisTheme.Spacing.m)
        }
    }

    private var providerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
                Text("Pick a free provider")
                    .font(JarvisTheme.Typography.title)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                Text("JARVIS ships without any key baked in — that is deliberate, so no secret is ever inside the app or the repository. Add your own free key in Settings ▸ AI Providers.")
                    .font(JarvisTheme.Typography.body)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                ForEach(ProviderCatalog.entries) { entry in
                    GlassCard(title: entry.displayName, subtitle: entry.defaultModel) {
                        Text(entry.freeTierNote)
                            .font(JarvisTheme.Typography.micro)
                            .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Terms verified on \(ProviderCatalog.verificationDate). Providers change limits; the app always shows the date and links to their documentation.")
                    .font(JarvisTheme.Typography.micro)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            }
            .padding(JarvisTheme.Spacing.m)
        }
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

    private func finish() {
        Haptics.success()
        onFinish()
    }
}
