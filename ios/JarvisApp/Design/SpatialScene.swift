import SwiftUI
#if canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Spatial layer: depth, parallax and light.
///
/// "Spatial" here means three concrete things, not a buzzword:
///  1. **Depth** — every surface sits at a layer, with its own shadow, rim light and
///     blur budget, so foreground panels read as floating in front of the backdrop.
///  2. **Parallax** — the device's own motion (CoreMotion attitude) shifts the layers
///     slightly and at different rates, which is what makes a UI feel like it occupies
///     space rather than being painted on the glass.
///  3. **Light** — specular highlights and glow that respond to state (idle, thinking,
///     speaking, error), so the surface looks lit rather than shaded.
///
/// Everything degrades honestly: no CoreMotion (simulator, or Reduce Motion on) means
/// the layers settle onto a slow ambient drift instead of pretending to track the hand.
/// Deliberately **not** `@MainActor`-isolated as a whole: it is created from a property
/// initialiser in the `App` struct, where a main-actor initialiser would not compile. Every
/// mutation below happens on the main actor explicitly (`Task { @MainActor in … }`), which
/// is the same pattern `SpeechSynthesizerService` uses.
public final class MotionParallax: ObservableObject {

    /// Radians, smoothed. `roll` is the tilt left/right, `pitch` is forward/back.
    @Published public private(set) var roll: Double = 0
    @Published public private(set) var pitch: Double = 0
    /// False when the effect is unavailable (no sensor, or Reduce Motion).
    @Published public private(set) var isLive = false

    private var driftTask: Task<Void, Never>?
    #if canImport(CoreMotion)
    private let manager = CMMotionManager()
    #endif

    public init() {}

    public func start() {
        #if canImport(CoreMotion)
        if UIAccessibility.isReduceMotionEnabled {
            startDrift(reason: "Reduce Motion is on")
            return
        }
        guard manager.isDeviceMotionAvailable else {
            startDrift(reason: "no motion sensor on this device")
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        // The handler runs on a background queue, so it computes a plain value and hops
        // to the main actor to publish it. Touching @MainActor state directly from this
        // closure would not compile (and would be a data race even if it did).
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical) { [weak self] motion, _ in
            guard let motion else { return }
            let roll = max(-1.0, min(1.0, motion.attitude.roll))
            let pitch = max(-1.0, min(1.0, motion.attitude.pitch))
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Heavy smoothing: the background should lag the hand slightly, which is
                // what sells the depth. Raw gyro values look jittery.
                self.roll = self.roll * 0.86 + roll * 0.14
                self.pitch = self.pitch * 0.86 + pitch * 0.14
                if !self.isLive { self.isLive = true }
            }
        }
        #else
        startDrift(reason: "CoreMotion unavailable")
        #endif
    }

    public func stop() {
        driftTask?.cancel()
        driftTask = nil
        #if canImport(CoreMotion)
        manager.stopDeviceMotionUpdates()
        #endif
        isLive = false
    }

    /// A gentle, slow drift used when real motion data is unavailable — never a
    /// simulation of hand tracking, just a quiet ambient movement.
    private func startDrift(reason: String) {
        guard driftTask == nil else { return }
        isLive = false
        driftTask = Task { @MainActor [weak self] in
            let start = Date()
            while !Task.isCancelled {
                guard let self else { return }
                let t = Date().timeIntervalSince(start)
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.roll = sin(t * 0.18) * 0.16
                    self.pitch = cos(t * 0.13) * 0.12
                }
                _ = reason
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    /// Parallax offset for a layer. Higher `depth` moves further.
    public func offset(depth: Double, magnitude: CGFloat = 18) -> CGSize {
        CGSize(width: CGFloat(-roll) * magnitude * depth,
               height: CGFloat(-pitch) * magnitude * 0.7 * depth)
    }

    /// A subtle 3D tilt for hero elements (the face, cards).
    public func tilt(depth: Double, degrees: Double = 7) -> (x: Double, y: Double, z: Double) {
        (x: -pitch * degrees * depth, y: roll * degrees * depth, z: 0)
    }
}

// MARK: - Depth tokens

public enum SpatialDepth {
    /// Shadow radius, y-offset and opacity per layer. Foreground layers cast further.
    public static func shadow(_ layer: Double, scheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
        let strength = scheme == .dark ? 0.55 : 0.18
        return (Color.black.opacity(strength * min(1.0, layer)), 18 * layer, 10 * layer)
    }
}

// MARK: - Backdrop

/// Layered atmosphere behind everything: three parallax strata plus a light bloom that
/// reacts to the assistant's state. Never intercepts touches — it is a background.
public struct SpatialBackdrop: View {
    @EnvironmentObject private var parallax: MotionParallax
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let state: AssistantState
    private let intensity: Double

    public init(state: AssistantState = .idle, intensity: Double = 1.0) {
        self.state = state
        self.intensity = intensity
    }

    private var accent: Color {
        switch state {
        case .idle: return JarvisTheme.Palette.ice
        case .listening: return JarvisTheme.Palette.cyan
        case .thinking, .executing: return JarvisTheme.Palette.ice
        case .speaking: return JarvisTheme.Palette.mint
        case .failed: return JarvisTheme.Palette.rose
        case .awaitingConfirmation: return JarvisTheme.Palette.amber
        }
    }

    public var body: some View {
        ZStack {
            // Stratum 0 — the deep field.
            LinearGradient(colors: scheme == .dark
                           ? [JarvisTheme.Palette.ink, JarvisTheme.Palette.graphite, JarvisTheme.Palette.ink]
                           : [Color(red: 0.95, green: 0.96, blue: 0.98),
                              Color(red: 0.90, green: 0.93, blue: 0.97),
                              Color(red: 0.95, green: 0.96, blue: 0.99)],
                           startPoint: .top, endPoint: .bottom)

            // Stratum 1 — a slow lattice that moves least (far away).
            Canvas { context, size in
                let spacing: CGFloat = 46
                var path = Path()
                var x: CGFloat = -spacing
                while x < size.width + spacing {
                    path.move(to: CGPoint(x: x, y: -spacing))
                    path.addLine(to: CGPoint(x: x, y: size.height + spacing))
                    x += spacing
                }
                var y: CGFloat = -spacing
                while y < size.height + spacing {
                    path.move(to: CGPoint(x: -spacing, y: y))
                    path.addLine(to: CGPoint(x: size.width + spacing, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(accent.opacity(scheme == .dark ? 0.045 : 0.05)),
                               lineWidth: 0.6)
            }
            .offset(parallax.offset(depth: 0.18))
            .blur(radius: 0.4)

            // Stratum 2 — two drifting light masses (far + near).
            bloom(size: 420, opacity: 0.20, offset: CGSize(width: -110, height: -180), depth: 0.42)
            bloom(size: 320, opacity: 0.14, offset: CGSize(width: 140, height: 220), depth: 0.78)

            // Stratum 3 — vignette to seat the content.
            RadialGradient(colors: [.clear, JarvisTheme.Palette.ink.opacity(scheme == .dark ? 0.55 : 0.06)],
                           center: .center, startRadius: 120, endRadius: 620)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : JarvisTheme.Motion.gentle, value: state)
    }

    private func bloom(size: CGFloat, opacity: Double, offset: CGSize, depth: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [accent.opacity(opacity * intensity), accent.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .offset(x: offset.width + parallax.offset(depth: depth).width,
                    y: offset.height + parallax.offset(depth: depth).height)
            .blur(radius: 6)
            .blendMode(scheme == .dark ? .plusLighter : .multiply)
            .opacity(scheme == .dark ? 1 : 0.5)
    }
}

// MARK: - Spatial surface

/// A depth-aware glass surface: layered fill, rim light, specular sweep and a shadow
/// sized to its layer. Replaces flat "card" styling for hero content.
public struct SpatialSurface<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let layer: Double
    private let prominence: Double
    private let cornerRadius: CGFloat
    private let accent: Color?
    private let content: Content

    public init(layer: Double = 1.0, prominence: Double = 0.5, cornerRadius: CGFloat = JarvisTheme.Radius.large,
                accent: Color? = nil, @ViewBuilder content: () -> Content) {
        self.layer = layer
        self.prominence = prominence
        self.cornerRadius = cornerRadius
        self.accent = accent
        self.content = content()
    }

    public var body: some View {
        content
            .padding(JarvisTheme.Spacing.m)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(
                                colors: scheme == .dark
                                    ? [Color.white.opacity(0.10 * prominence), Color.white.opacity(0.02), Color.black.opacity(0.16)]
                                    : [Color.white.opacity(0.85), Color.white.opacity(0.45), Color.black.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay {
                        // Rim light: brighter at the top edge, as if lit from above.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(LinearGradient(
                                colors: [(accent ?? JarvisTheme.Palette.silver).opacity(0.55),
                                         (accent ?? JarvisTheme.Palette.ice).opacity(0.10),
                                         Color.clear],
                                startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
                    .overlay {
                        if let accent, !reduceMotion {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                                .blur(radius: 3)
                                .opacity(prominence)
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: SpatialDepth.shadow(layer, scheme: scheme).color,
                    radius: SpatialDepth.shadow(layer, scheme: scheme).radius,
                    y: SpatialDepth.shadow(layer, scheme: scheme).y)
    }
}

/// Applies a parallax shift + 3D tilt to a view without needing a GeometryReader.
public struct SpatialParallaxModifier: ViewModifier {
    @EnvironmentObject private var parallax: MotionParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let depth: Double
    let magnitude: CGFloat
    let tiltDegrees: Double

    public func body(content: Content) -> some View {
        let offset = parallax.offset(depth: depth, magnitude: magnitude)
        let angles = parallax.tilt(depth: depth, degrees: tiltDegrees)
        return content
            .offset(x: reduceMotion ? 0 : offset.width, y: reduceMotion ? 0 : offset.height)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : angles.x), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : angles.y), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .animation(reduceMotion ? nil : JarvisTheme.Motion.smooth, value: offset.width)
            .animation(reduceMotion ? nil : JarvisTheme.Motion.smooth, value: offset.height)
    }
}

public extension View {
    /// Floats this view at `depth` (0 = far backdrop, 1 = hero, 1.6 = raised panel).
    func spatial(depth: Double, magnitude: CGFloat = 16, tiltDegrees: Double = 5) -> some View {
        modifier(SpatialParallaxModifier(depth: depth, magnitude: magnitude, tiltDegrees: tiltDegrees))
    }
}
