import SwiftUI

/// Top-level navigation. A compact custom tab bar keeps the glass language
/// consistent and leaves room for the safe area on every device.
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
    @State private var selection: Tab = .assistant
    @State private var assistantModel: AssistantViewModel?
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selection {
                case .assistant:
                    if let assistantModel {
                        AssistantHomeView(model: assistantModel)
                    } else {
                        ProgressView().tint(JarvisTheme.Palette.ice)
                    }
                case .memory:
                    MemoryCenterView()
                case .tasks:
                    TasksView()
                case .services:
                    ConnectedServicesView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabBar
        }
        .background(AmbientBackground().ignoresSafeArea())
        .task {
            if assistantModel == nil { assistantModel = AssistantViewModel(environment: environment) }
            await assistantModel?.start()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                Button {
                    Haptics.selection()
                    withAnimation(JarvisTheme.Motion.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: selection == tab ? .semibold : .regular))
                        Text(tab.title)
                            .font(JarvisTheme.Typography.micro)
                    }
                    .foregroundStyle(selection == tab
                                     ? JarvisTheme.Palette.primaryText(scheme)
                                     : JarvisTheme.Palette.tertiaryText(scheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: JarvisTheme.Radius.small, style: .continuous)
                                .fill(JarvisTheme.Palette.ice.opacity(scheme == .dark ? 0.16 : 0.14))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(6)
        .jarvisGlass(.strong, cornerRadius: JarvisTheme.Radius.large)
        .padding(.horizontal, JarvisTheme.Spacing.m)
        .padding(.bottom, JarvisTheme.Spacing.xs)
    }
}
