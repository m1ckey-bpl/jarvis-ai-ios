import SwiftUI

/// Top-level navigation.
///
/// Layout note (this was a real bug in the first device build): the tab bar used to be
/// an *overlay* — `ZStack(alignment: .bottom)` — so anything a screen put near its
/// bottom edge sat underneath the bar. Buttons were visible but unreachable, and taps
/// landed on the bar instead. The content and the bar are now laid out as siblings in a
/// `VStack`, so the content area ends where the bar begins. Nothing can hide behind it.
public struct NavigationShell: View {

    public enum Tab: String, CaseIterable, Identifiable {
        case assistant, memory, tasks, services, settings

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .assistant: return "Assistant"
            case .memory: return "Memory"
            case .tasks: return "Tasks"
            case .services: return "Services"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .assistant: return "circle.hexagongrid.fill"
            case .memory: return "brain.head.profile"
            case .tasks: return "checklist"
            case .services: return "link.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var parallax: MotionParallax
    @State private var selection: Tab = .assistant
    @State private var assistantModel: AssistantViewModel?
    @State private var assistantState: AssistantState = .idle
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            // Atmosphere sits behind everything; it never takes touches.
            SpatialBackdrop(state: assistantState)
                .transition(.opacity)

            VStack(spacing: 0) {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                tabBar
            }
        }
        .task {
            if assistantModel == nil { assistantModel = AssistantViewModel(environment: environment) }
            await assistantModel?.start()
        }
        .onAppear { parallax.start() }
        .onDisappear { parallax.stop() }
    }

    @ViewBuilder
    private var screen: some View {
        switch selection {
        case .assistant:
            if let assistantModel {
                AssistantHomeView(model: assistantModel, onStateChange: { assistantState = $0 })
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: JarvisTheme.Spacing.m) {
                    LoadingDots()
                    Text("Waking JARVIS…")
                        .font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .memory:
            MemoryCenterView().transition(.opacity)
        case .tasks:
            TasksView().transition(.opacity)
        case .services:
            ConnectedServicesView().transition(.opacity)
        case .settings:
            SettingsView().transition(.opacity)
        }
    }

    private var tabBar: some View {
        HStack(spacing: JarvisTheme.Spacing.xs) {
            ForEach(Tab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(6)
        .jarvisGlass(.strong, cornerRadius: JarvisTheme.Radius.large)
        .padding(.horizontal, JarvisTheme.Spacing.m)
        .padding(.top, JarvisTheme.Spacing.xs)
        .padding(.bottom, JarvisTheme.Spacing.xs)
        // The bar itself is chrome: it should not swallow taps meant for nothing in
        // particular, but every button inside it is a real 44pt target.
        .background(Color.clear)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let isSelected = selection == tab
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : JarvisTheme.Motion.snappy) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                Text(tab.title)
                    .font(JarvisTheme.Typography.micro)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isSelected
                             ? JarvisTheme.Palette.primaryText(scheme)
                             : JarvisTheme.Palette.tertiaryText(scheme))
            // 44pt minimum: the whole cell is tappable, not just the glyph.
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 2)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: JarvisTheme.Radius.small, style: .continuous)
                        .fill(JarvisTheme.Palette.ice.opacity(scheme == .dark ? 0.16 : 0.14))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityHint(isSelected ? "Currently shown" : "Shows the \(tab.title) screen")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
