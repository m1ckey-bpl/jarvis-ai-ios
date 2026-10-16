import SwiftUI

// MARK: - Cards & containers

/// A glass panel with an optional title and trailing accessory.
public struct GlassCard<Content: View>: View {
    private let title: String?
    private let subtitle: String?
    private let accent: Color?
    private let content: Content

    public init(title: String? = nil, subtitle: String? = nil, accent: Color? = nil,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.content = content()
    }

    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        VStack(alignment: .leading, spacing: JarvisTheme.Spacing.m) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(title)
                            .font(JarvisTheme.Typography.headline)
                            .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(JarvisTheme.Typography.caption)
                            .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    }
                }
            }
            content
        }
        .padding(JarvisTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jarvisGlass(.regular, cornerRadius: JarvisTheme.Radius.large, accent: accent)
    }
}

// MARK: - Buttons

/// Primary action button. A disabled button always explains itself.
public struct GlassButton: View {
    public enum Style { case primary, secondary, destructive, quiet }

    private let title: String
    private let systemImage: String?
    private let style: Style
    private let isEnabled: Bool
    private let disabledReason: String?
    private let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isPressed = false

    public init(_ title: String, systemImage: String? = nil, style: Style = .primary,
                isEnabled: Bool = true, disabledReason: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.action = action
    }

    public var body: some View {
        Button(action: {
            guard isEnabled else { return }
            Haptics.tap()
            action()
        }) {
            HStack(spacing: JarvisTheme.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(JarvisTheme.Typography.callout)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, JarvisTheme.Spacing.m)
            .padding(.vertical, JarvisTheme.Spacing.s)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: JarvisTheme.Radius.pill, style: .continuous)
                    .fill(background)
                    .overlay {
                        RoundedRectangle(cornerRadius: JarvisTheme.Radius.pill, style: .continuous)
                            .strokeBorder(JarvisTheme.Palette.hairline(scheme), lineWidth: 0.75)
                    }
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.55)
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(JarvisTheme.Motion.snappy, value: isPressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { _ in isPressed = false })
        .accessibilityLabel(title)
        .accessibilityHint(isEnabled ? "" : (disabledReason ?? "Unavailable"))
        .accessibilityAddTraits(isEnabled ? [] : [.isStaticText])
    }

    private var foreground: Color {
        switch style {
        case .primary: return JarvisTheme.Palette.ink
        case .secondary: return JarvisTheme.Palette.primaryText(scheme)
        case .destructive: return .white
        case .quiet: return JarvisTheme.Palette.secondaryText(scheme)
        }
    }

    private var background: Color {
        switch style {
        case .primary: return JarvisTheme.Palette.ice.opacity(0.95)
        case .secondary: return JarvisTheme.Palette.elevated(scheme).opacity(scheme == .dark ? 0.12 : 0.7)
        case .destructive: return JarvisTheme.Palette.danger.opacity(0.9)
        case .quiet: return .clear
        }
    }
}

// MARK: - Status & messaging

/// Compact state pill used across screens.
public struct StatusPill: View {
    public var text: String
    public var systemImage: String
    public var tint: Color

    public init(text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            Text(text).font(JarvisTheme.Typography.micro)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(tint.opacity(0.14))
                .overlay { Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.6) }
        }
        .accessibilityElement(children: .combine)
    }

    /// Maps a capability state to a consistent pill.
    public static func forCapability(_ state: CapabilityState) -> StatusPill {
        switch state {
        case .ready:
            return StatusPill(text: "Ready", systemImage: "checkmark.circle.fill", tint: JarvisTheme.Palette.success)
        case .requiresConfiguration:
            return StatusPill(text: "Setup needed", systemImage: "slider.horizontal.3", tint: JarvisTheme.Palette.warning)
        case .requiresPermission:
            return StatusPill(text: "Permission", systemImage: "hand.raised.fill", tint: JarvisTheme.Palette.warning)
        case .requiresBackend:
            return StatusPill(text: "Needs backend", systemImage: "cloud.slash", tint: JarvisTheme.Palette.warning)
        case .exhausted:
            return StatusPill(text: "Quota reached", systemImage: "hourglass", tint: JarvisTheme.Palette.danger)
        case .unavailable:
            return StatusPill(text: "Unavailable", systemImage: "xmark.circle", tint: JarvisTheme.Palette.tertiaryText(.dark))
        }
    }
}

/// Empty state used by memory, tasks, history and services screens.
public struct EmptyStateView: View {
    public var title: String
    public var message: String
    public var systemImage: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    public init(title: String, message: String, systemImage: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title; self.message = message; self.systemImage = systemImage
        self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        VStack(spacing: JarvisTheme.Spacing.m) {
            OrbitalGlyph(systemImage: systemImage)
            VStack(spacing: JarvisTheme.Spacing.xs) {
                Text(title)
                    .font(JarvisTheme.Typography.headline)
                    .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                Text(message)
                    .font(JarvisTheme.Typography.caption)
                    .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                GlassButton(actionTitle, style: .secondary, action: action)
            }
        }
        .padding(JarvisTheme.Spacing.l)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Native vector "illustration": concentric orbital rings with a glyph.
/// Original artwork, drawn at runtime — no raster asset, no copyrighted imagery.
public struct OrbitalGlyph: View {
    public var systemImage: String
    public var tint: Color

    public init(systemImage: String, tint: Color = JarvisTheme.Palette.ice) {
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Ellipse().stroke(tint.opacity(0.35), lineWidth: 0.8)
                .frame(width: 132, height: 76)
                .rotationEffect(.degrees(-18))
            Ellipse().stroke(tint.opacity(0.22), lineWidth: 0.8)
                .frame(width: 106, height: 106)
                .rotationEffect(.degrees(24))
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.35), .clear], center: .center, startRadius: 2, endRadius: 54))
                .frame(width: 108, height: 108)
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tint)
        }
        .frame(width: 150, height: 150)
        .accessibilityHidden(true)
    }
}

/// Inline banner for errors and setup prompts. Never shows raw stack traces.
public struct InlineBanner: View {
    public enum Kind { case info, warning, error, success }
    public var kind: Kind
    public var title: String
    public var message: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    public init(kind: Kind, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind; self.title = title; self.message = message
        self.actionTitle = actionTitle; self.action = action
    }

    private var tint: Color {
        switch kind {
        case .info: return JarvisTheme.Palette.info
        case .warning: return JarvisTheme.Palette.warning
        case .error: return JarvisTheme.Palette.danger
        case .success: return JarvisTheme.Palette.success
        }
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.seal.fill"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: JarvisTheme.Spacing.s) {
            HStack(alignment: .top, spacing: JarvisTheme.Spacing.s) {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(JarvisTheme.Typography.callout)
                        .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
                    Text(message).font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let actionTitle, let action {
                GlassButton(actionTitle, style: .secondary, action: action)
            }
        }
        .padding(JarvisTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: JarvisTheme.Radius.medium, style: .continuous)
                .fill(tint.opacity(scheme == .dark ? 0.12 : 0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: JarvisTheme.Radius.medium, style: .continuous)
                        .strokeBorder(tint.opacity(0.30), lineWidth: 0.7)
                }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Section header with an optional trailing accessory.
public struct SectionHeader<Accessory: View>: View {
    public var title: String
    public var subtitle: String?
    @ViewBuilder public var accessory: () -> Accessory

    @Environment(\.colorScheme) private var scheme

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.accessory = accessory
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(JarvisTheme.Typography.micro)
                    .tracking(1.2)
                    .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
                if let subtitle {
                    Text(subtitle).font(JarvisTheme.Typography.caption)
                        .foregroundStyle(JarvisTheme.Palette.secondaryText(scheme))
                }
            }
            Spacer(minLength: JarvisTheme.Spacing.s)
            accessory()
        }
    }
}

public extension SectionHeader where Accessory == EmptyView {
    /// Header without a trailing accessory — the common case in the app screens.
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

/// Row used by the services/settings lists: title, subtitle, state pill, action.
public struct CapabilityRow: View {
    public var title: String
    public var subtitle: String
    public var state: CapabilityState
    public var actionTitle: String?
    public var action: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    public init(title: String, subtitle: String, state: CapabilityState, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.state = state
        self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
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
            if let actionTitle, let action, !state.isUsable {
                GlassButton(actionTitle, style: .secondary, action: action)
            }
        }
        .padding(JarvisTheme.Spacing.m)
        .jarvisGlass(.subtle, cornerRadius: JarvisTheme.Radius.medium)
    }
}

/// Three-dot "working" indicator (used where a determinate progress is unknown).
public struct LoadingDots: View {
    public var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color = JarvisTheme.Palette.ice) { self.tint = tint }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let offset = (sin((phase * 2.4) + Double(index) * 0.7) + 1) / 2
                    Circle()
                        .fill(tint.opacity(0.35 + 0.6 * offset))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .accessibilityLabel("Working")
    }
}

/// Small metric tile (memory count, tokens, latency…).
public struct MetricTile: View {
    public var label: String
    public var value: String
    public var tint: Color

    @Environment(\.colorScheme) private var scheme

    public init(label: String, value: String, tint: Color = JarvisTheme.Palette.ice) {
        self.label = label; self.value = value; self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(JarvisTheme.Typography.micro).tracking(1)
                .foregroundStyle(JarvisTheme.Palette.tertiaryText(scheme))
            Text(value)
                .font(JarvisTheme.Typography.timer)
                .foregroundStyle(JarvisTheme.Palette.primaryText(scheme))
        }
        .padding(.horizontal, JarvisTheme.Spacing.s)
        .padding(.vertical, JarvisTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: JarvisTheme.Radius.small, style: .continuous)
                .fill(tint.opacity(scheme == .dark ? 0.10 : 0.08))
        }
        .accessibilityElement(children: .combine)
    }
}
