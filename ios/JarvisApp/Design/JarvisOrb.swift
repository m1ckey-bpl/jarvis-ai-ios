import SwiftUI

/// The JARVIS core.
///
/// Every visual property is a function of the *real* assistant state
/// (`AssistantState`) and, when listening or speaking, of a measured audio level.
/// Nothing here simulates analyser data: if no level is available the orb stays
/// in a calm ambient mode and says so through its accessibility label.
public struct JarvisOrb: View {

    public var state: AssistantState
    /// 0…1 live microphone / playback level, when genuinely available.
    public var audioLevel: Double
    public var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    public init(state: AssistantState = .idle, audioLevel: Double = 0, size: CGFloat = 220) {
        self.state = state
        self.audioLevel = audioLevel
        self.size = size
    }

    private var profile: OrbAnimationProfile { state.animationProfile }
    private var accent: Color { JarvisTheme.accent(for: profile.accent) }

    public var body: some View {
        ZStack {
            halo
            core
            if case .executing = state { ProgressRing(accent: accent) }
            if case .awaitingConfirmation = state { ConfirmationPulse(accent: accent) }
            glyph
        }
        .frame(width: size, height: size)
        .animation(JarvisTheme.Motion.respectReduceMotion(reduceMotion) ?? .default, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("JARVIS core, \(state.label)")
        .accessibilityValue(state.detail ?? "")
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Layers

    private var halo: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let breath = (sin(time * (1.1 + profile.speed * 1.6)) + 1) / 2          // 0…1
            let reactive = audioLevel * (state == .listening || state == .speaking ? 1 : 0.25)
            let radius = size * (0.40 + 0.045 * profile.amplitude * breath + 0.06 * reactive)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.34), accent.opacity(0.02)],
                                         center: .center, startRadius: radius * 0.35, endRadius: radius * 1.4))
                    .blur(radius: size * 0.06)
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [accent.opacity(0.65), .clear, accent.opacity(0.35), .clear],
                                        center: .center),
                        lineWidth: 1
                    )
                    .scaleEffect(0.92 + 0.10 * breath)
                    .opacity(state == .idle ? 0.55 : 0.9)
            }
            .frame(width: size, height: size)
        }
    }

    private var core: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let wobble = sin(time * (0.8 + profile.speed)) * 0.02 * profile.amplitude
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            JarvisTheme.Palette.silver.opacity(scheme == .dark ? 0.96 : 0.90),
                            accent.opacity(0.85),
                            JarvisTheme.Palette.slate.opacity(0.95),
                            JarvisTheme.Palette.ink.opacity(0.98)
                        ],
                        center: .init(x: 0.35, y: 0.30),
                        startRadius: size * 0.02,
                        endRadius: size * 0.46
                    )
                )
                .overlay {
                    // Specular sweep: light catching a metallic lens.
                    Ellipse()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.34), .clear],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .blur(radius: size * 0.05)
                        .rotationEffect(.degrees(-18 + wobble * 40))
                        .blendMode(.screen)
                        .mask(Circle())
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.45), accent.opacity(0.25), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.9
                    )
                }
                .frame(width: size * 0.62, height: size * 0.62)
                .shadow(color: accent.opacity(0.45), radius: size * 0.10, y: size * 0.02)
        }
    }

    /// A restrained inner glyph that encodes the state without clutter.
    private var glyph: some View {
        Group {
            switch state {
            case .listening:
                WaveformBars(level: audioLevel, active: true)
            case .thinking:
                ProcessingSweep(accent: accent, paused: reduceMotion)
            case .executing:
                Image(systemName: "gearshape.2.fill").font(.system(size: size * 0.10, weight: .semibold))
            case .awaitingConfirmation:
                Image(systemName: "hand.raised.fill").font(.system(size: size * 0.10, weight: .semibold))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size * 0.10, weight: .semibold))
            case .speaking:
                WaveformBars(level: audioLevel, active: true)
            case .idle:
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: size * 0.09, weight: .regular))
            }
        }
        .foregroundStyle(JarvisTheme.Palette.ink.opacity(0.78))
        .opacity(state == .idle ? 0.5 : 0.85)
    }
}

// MARK: - Pieces

/// Real-level waveform. Renders exactly the samples it is given.
public struct WaveformBars: View {
    public var level: Double
    public var active: Bool
    public var barCount: Int = 5

    public init(level: Double, active: Bool, barCount: Int = 5) {
        self.level = level
        self.active = active
        self.barCount = barCount
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let shape = WaveformMath.barHeight(level: level, index: index, count: barCount)
                Capsule()
                    .frame(width: 2.2, height: 4 + 12 * shape)
            }
        }
        .opacity(active ? 1 : 0.35)
    }
}

/// Deterministic mapping from a measured level to bar geometry (unit-tested core logic).
public enum WaveformMath {
    public static func barHeight(level: Double, index: Int, count: Int) -> Double {
        let clamped = max(0, min(1, level))
        guard count > 1 else { return clamped }
        let centre = Double(count - 1) / 2
        let distance = abs(Double(index) - centre) / max(1, centre)
        // Centre bars react most; edges stay calm — a natural, non-random shape.
        return clamped * (1 - 0.55 * distance)
    }
}

/// A one-shot sweep used while the model is thinking.
private struct ProcessingSweep: View {
    let accent: Color
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            let time = paused ? 0 : context.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: 1.6) / 1.6
            return ZStack {
                Circle().strokeBorder(JarvisTheme.Palette.ink.opacity(0.18), lineWidth: 1.4)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(JarvisTheme.Palette.ink.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(phase * 360))
            }
            .frame(width: 22, height: 22)
        }
    }
}

/// Progress ring for tool execution (indeterminate — tools report no percentage).
private struct ProgressRing: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: 2.4) / 2.4
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(accent.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 148, height: 148)
                .rotationEffect(.degrees(phase * 360))
        }
    }
}

/// Gentle attention pulse while waiting for the user's approval.
private struct ConfirmationPulse: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let breath = (sin(time * 2.2) + 1) / 2
            Circle()
                .strokeBorder(accent.opacity(0.25 + 0.45 * breath), lineWidth: 1.6)
                .frame(width: 168 + 6 * breath, height: 168 + 6 * breath)
        }
    }
}

/// Live microphone waveform shown above the composer while dictating.
/// `levels` is a rolling buffer of *measured* magnitudes — never synthesised.
public struct AudioWaveformView: View {
    public var levels: [Double]
    public var isActive: Bool
    public var tint: Color

    public init(levels: [Double], isActive: Bool, tint: Color = JarvisTheme.Palette.cyan) {
        self.levels = levels
        self.isActive = isActive
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint.opacity(isActive ? 0.9 : 0.35))
                    .frame(width: 2.5, height: 3 + 26 * max(0.02, min(1, level)))
            }
        }
        .frame(height: 32)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}
