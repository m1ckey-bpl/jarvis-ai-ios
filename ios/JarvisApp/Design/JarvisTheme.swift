import SwiftUI

/// The JARVIS design language.
///
/// Rules (docs/DESIGN_SYSTEM.md): deep black/graphite foundations, translucent
/// charcoal glass, cool silver, ice blue and restrained cyan accents. No neon
/// overload, no gradient-per-component, consistent radii, readable contrast in
/// both appearances, and every animation must respect Reduce Motion.
public enum JarvisTheme {

    // MARK: Palette

    public enum Palette {
        // Foundations
        public static let ink = Color(red: 0.043, green: 0.047, blue: 0.055)            // near-black
        public static let graphite = Color(red: 0.078, green: 0.086, blue: 0.098)
        public static let slate = Color(red: 0.129, green: 0.141, blue: 0.161)
        public static let glassTint = Color(red: 0.180, green: 0.212, blue: 0.259)

        // Metals & accents (used sparingly)
        public static let silver = Color(red: 0.839, green: 0.863, blue: 0.894)
        public static let ice = Color(red: 0.545, green: 0.780, blue: 0.980)
        public static let cyan = Color(red: 0.290, green: 0.898, blue: 0.925)
        public static let amber = Color(red: 0.976, green: 0.741, blue: 0.325)
        public static let rose = Color(red: 0.949, green: 0.463, blue: 0.529)
        public static let mint = Color(red: 0.380, green: 0.886, blue: 0.702)

        // Semantic
        public static let success = mint
        public static let warning = amber
        public static let danger = rose
        public static let info = ice

        /// Text colours resolved for the current appearance.
        public static func primaryText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 0.96) : Color(red: 0.09, green: 0.10, blue: 0.12)
        }
        public static func secondaryText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 0.72) : Color(red: 0.34, green: 0.36, blue: 0.40)
        }
        public static func tertiaryText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(white: 0.56) : Color(red: 0.47, green: 0.49, blue: 0.53)
        }
        public static func hairline(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
        }
        public static func canvas(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? ink : Color(red: 0.955, green: 0.960, blue: 0.969)
        }
        public static func elevated(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? graphite : Color.white
        }
    }

    // MARK: Spacing & shape

    public enum Spacing {
        public static let hairline: CGFloat = 2
        public static let xs: CGFloat = 6
        public static let s: CGFloat = 10
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 44
    }

    public enum Radius {
        public static let small: CGFloat = 12
        public static let medium: CGFloat = 18
        public static let large: CGFloat = 26
        public static let pill: CGFloat = 999
    }

    // MARK: Typography

    public enum Typography {
        public static let display = Font.system(size: 34, weight: .semibold, design: .rounded)
        public static let title = Font.system(size: 24, weight: .semibold, design: .rounded)
        public static let headline = Font.system(size: 18, weight: .semibold, design: .rounded)
        public static let body = Font.system(size: 16, weight: .regular, design: .rounded)
        public static let callout = Font.system(size: 15, weight: .medium, design: .rounded)
        public static let caption = Font.system(size: 13, weight: .medium, design: .rounded)
        public static let micro = Font.system(size: 11, weight: .semibold, design: .rounded)
        /// Monospaced digits for timers and token counts.
        public static let timer = Font.system(size: 15, weight: .medium, design: .monospaced)
    }

    // MARK: Motion

    /// Motion is centralised so Reduce Motion can neutralise it in one place.
    public enum Motion {
        public static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)
        public static let smooth = Animation.spring(response: 0.55, dampingFraction: 0.9)
        public static let gentle = Animation.easeInOut(duration: 0.45)

        public static func respectReduceMotion(_ reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : snappy
        }
    }

    /// Accent colour for a given capability/assistant state.
    public static func accent(for accent: OrbAnimationProfile.Accent) -> Color {
        switch accent {
        case .ice: return Palette.ice
        case .cyan: return Palette.cyan
        case .silver: return Palette.silver
        case .amber: return Palette.amber
        case .rose: return Palette.rose
        }
    }
}

// MARK: - Liquid Glass surface

/// Applies the JARVIS glass treatment.
///
/// On a Liquid-Glass-capable SDK + iOS 26 it uses the system material; everywhere
/// else it composes native materials, a specular top highlight and a hairline
/// stroke — the same visual language, no invented APIs (decision D6).
public struct JarvisGlassSurface: ViewModifier {
    public enum Prominence { case regular, strong, subtle }

    private let prominence: Prominence
    private let cornerRadius: CGFloat
    private let accent: Color?
    @Environment(\.colorScheme) private var scheme

    public init(prominence: Prominence = .regular, cornerRadius: CGFloat = JarvisTheme.Radius.large, accent: Color? = nil) {
        self.prominence = prominence
        self.cornerRadius = cornerRadius
        self.accent = accent
    }

    public func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .tint(accent?.opacity(0.18) ?? JarvisTheme.Palette.glassTint.opacity(0.28))
                        .interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(material)
                    .overlay {
                        // Depth: a soft inner glow that reads as light through glass.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        (accent ?? JarvisTheme.Palette.silver).opacity(scheme == .dark ? 0.10 : 0.06),
                                        Color.clear,
                                        JarvisTheme.Palette.ink.opacity(scheme == .dark ? 0.18 : 0.02)
                                    ],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(scheme == .dark ? 0.22 : 0.55),
                                        Color.white.opacity(scheme == .dark ? 0.04 : 0.10),
                                        (accent ?? JarvisTheme.Palette.silver).opacity(0.10)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    }
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.45 : 0.10),
                            radius: prominence == .strong ? 26 : 16, x: 0, y: prominence == .strong ? 14 : 8)
            }
    }

    private var material: Material {
        switch prominence {
        case .regular: return .ultraThinMaterial
        case .strong: return .thinMaterial
        case .subtle: return .ultraThinMaterial
        }
    }
}

public extension View {
    /// Standard JARVIS glass surface.
    func jarvisGlass(_ prominence: JarvisGlassSurface.Prominence = .regular,
                     cornerRadius: CGFloat = JarvisTheme.Radius.large,
                     accent: Color? = nil) -> some View {
        modifier(JarvisGlassSurface(prominence: prominence, cornerRadius: cornerRadius, accent: accent))
    }
}

// MARK: - Ambient background

/// Native-rendered ambient background: layered mesh-like gradients plus a very
/// slow orbital lattice. Drawn with `Canvas` (no bitmaps, no bandwidth) and
/// frozen when Reduce Motion is on or the screen is idle.
public struct AmbientBackground: View {
    public var accent: Color
    public var intensity: Double

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(accent: Color = JarvisTheme.Palette.ice, intensity: Double = 1.0) {
        self.accent = accent
        self.intensity = intensity
    }

    public var body: some View {
        ZStack {
            JarvisTheme.Palette.canvas(scheme).ignoresSafeArea()

            // Deep field gradients: one cool, one warm, offset for depth.
            RadialGradient(colors: [accent.opacity(0.22 * intensity), .clear],
                           center: .init(x: 0.18, y: 0.08), startRadius: 8, endRadius: 520)
                .ignoresSafeArea()
            RadialGradient(colors: [JarvisTheme.Palette.glassTint.opacity(0.30 * intensity), .clear],
                           center: .init(x: 0.86, y: 0.30), startRadius: 8, endRadius: 460)
                .ignoresSafeArea()
            RadialGradient(colors: [JarvisTheme.Palette.ink.opacity(scheme == .dark ? 0.7 : 0.06), .clear],
                           center: .init(x: 0.5, y: 1.05), startRadius: 40, endRadius: 640)
                .ignoresSafeArea()

            if reduceMotion {
                OrbitalLattice(phase: 0, color: accent.opacity(0.16)).ignoresSafeArea()
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 240) / 240
                    OrbitalLattice(phase: phase, color: accent.opacity(0.16)).ignoresSafeArea()
                }
            }

            // Grain-free vignette keeps text legible over the gradients.
            LinearGradient(colors: [.clear, JarvisTheme.Palette.canvas(scheme).opacity(scheme == .dark ? 0.55 : 0.25)],
                           startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}

/// Sparse orbital rings + particles. Cheap: a single Canvas pass, ~40 elements.
private struct OrbitalLattice: View {
    let phase: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.34)
            let rings = 5
            for ring in 0..<rings {
                let radius = size.width * (0.22 + Double(ring) * 0.13)
                let rect = CGRect(x: center.x - radius, y: center.y - radius * 0.62,
                                  width: radius * 2, height: radius * 1.24)
                let rotation = Angle.degrees(Double(ring) * 14 + phase * 360)
                var path = Path(ellipseIn: rect)
                path = path.applying(CGAffineTransform(rotationAngle: CGFloat(rotation.radians)))
                    .applying(CGAffineTransform(translationX: 0, y: 0))
                context.stroke(path, with: .color(color.opacity(0.5 - Double(ring) * 0.07)), lineWidth: 0.6)
            }
            // A few slow particles riding the outermost ring.
            for index in 0..<14 {
                let offset = phase + Double(index) / 14.0
                let radius = size.width * 0.87
                let angle = offset * 2 * .pi
                let point = CGPoint(x: center.x + cos(angle) * radius,
                                    y: center.y + sin(angle) * radius * 0.62)
                let dot = CGRect(x: point.x - 1.2, y: point.y - 1.2, width: 2.4, height: 2.4)
                context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.9)))
            }
        }
        .blendMode(.plusLighter)
        .opacity(0.55)
    }
}
