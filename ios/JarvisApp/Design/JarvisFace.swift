import SwiftUI

/// JARVIS's face: an original, abstract android visage (polished silver cranium, a
/// single dark visor with luminous optics, a segmented light mouth). Nothing here is
/// derived from any film, game or comic character — it is built from primitives in
/// this repository.
///
/// The mouth is **driven by the speech synthesiser**, not by a decorative loop:
/// `SpeechSynthesizerService` reports the character range it is speaking
/// (`willSpeakRangeOfSpeechString`) and maps the letter being pronounced to a
/// `Viseme` plus a jaw opening. So the lips follow the words, and stop when the
/// voice stops. Eyes blink on a timer, the gaze leans with the device's tilt, and
/// every state (idle, listening, thinking, speaking, executing, error,
/// confirmation) has its own light.
///
/// Reduce Motion turns off parallax, scanning and blinking — the face stays legible
/// and calm instead of animating for its own sake.
public struct JarvisFace: View {

    public var state: AssistantState
    /// Jaw openness, 0…1, supplied by the speech synthesizer while it talks.
    public var mouth: Double
    /// Which letter shape the mouth is making right now.
    public var viseme: Viseme
    /// Normalised device tilt, used for a small gaze shift.
    public var gaze: CGSize
    /// Width of the face in points; everything else scales from it.
    public var size: CGFloat
    /// Optional microphone level while listening.
    public var listeningLevel: Double

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: AssistantState, mouth: Double = 0, viseme: Viseme = .rest,
                gaze: CGSize = .zero, size: CGFloat = 240, listeningLevel: Double = 0) {
        self.state = state
        self.mouth = mouth
        self.viseme = viseme
        self.gaze = gaze
        self.size = size
        self.listeningLevel = listeningLevel
    }

    // MARK: - Light per state

    private var accent: Color {
        switch state {
        case .idle: return JarvisTheme.Palette.ice
        case .listening: return JarvisTheme.Palette.cyan
        case .thinking: return JarvisTheme.Palette.ice
        case .speaking: return JarvisTheme.Palette.mint
        case .executing: return JarvisTheme.Palette.amber
        case .failed: return JarvisTheme.Palette.rose
        case .awaitingConfirmation: return JarvisTheme.Palette.amber
        }
    }

    /// `.failed(message:)` and `.executing(tool:detail:)` carry payloads, so `state == .failed`
    /// is not a valid comparison — the compiler's error for it is memorable and misleading
    /// ("cannot convert value of type 'AssistantState' to expected argument type
    /// 'PencilSqueezeGesturePhase'"). These helpers are how the view asks the question.
    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var isExecuting: Bool {
        if case .executing = state { return true }
        return false
    }

    private var glowStrength: Double {
        switch state {
        case .idle: return 0.55
        case .listening: return 0.95
        case .thinking: return 0.75
        case .speaking: return 1.0
        case .executing: return 0.9
        case .failed: return 0.85
        case .awaitingConfirmation: return 0.9
        }
    }

    private var headHeight: CGFloat { size * 1.16 }

    public var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 6.0 : 1.0 / 30.0,
                                paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 0 : sin(t * 1.05)
            let blink = reduceMotion ? 1 : Self.blinkFactor(at: t, state: state)

            ZStack {
                halo(t: t)
                headGroup(breath: breath, blink: blink, t: t)
            }
            .frame(width: size * 1.5, height: headHeight * 1.32)
            .compositingGroup()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isImage)
    }

    private var accessibilityDescription: String {
        switch state {
        case .idle: return "JARVIS, idle, waiting for you"
        case .listening: return "JARVIS, listening"
        case .thinking: return "JARVIS, thinking"
        case .speaking: return "JARVIS, speaking"
        case .executing: return "JARVIS, running a tool"
        case .failed(let message): return "JARVIS, error: \(message)"
        case .awaitingConfirmation: return "JARVIS, waiting for your approval"
        }
    }

    // MARK: - Layers

    private func halo(t: TimeInterval) -> some View {
        let pulse = reduceMotion ? 0.6 : 0.5 + 0.5 * sin(t * (state == .speaking ? 6.0 : 1.6))
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.30 * glowStrength),
                                              accent.opacity(0.06),
                                              .clear],
                                     center: .center, startRadius: size * 0.12, endRadius: size * 0.86))
                .frame(width: size * 1.7, height: size * 1.7)
                .scaleEffect(1.0 + 0.035 * pulse)
                .blur(radius: 12)

            if case .thinking = state, !reduceMotion {
                Circle()
                    .trim(from: 0.05, to: 0.42)
                    .stroke(AngularGradient(colors: [.clear, accent.opacity(0.85), .clear], center: .center),
                            style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                    .frame(width: size * 1.42, height: size * 1.42)
                    .rotationEffect(.degrees(t * 90))
            }
            if case .executing = state, !reduceMotion {
                Circle()
                    .stroke(accent.opacity(0.35), lineWidth: size * 0.012)
                    .frame(width: size * 1.2, height: size * 1.2)
                    .scaleEffect(1.0 + 0.08 * pulse)
                    .opacity(1.0 - pulse)
            }
        }
        .allowsHitTesting(false)
    }

    private func headGroup(breath: Double, blink: Double, t: TimeInterval) -> some View {
        let gazeX = gaze.width * size * 0.045
        let gazeY = gaze.height * size * 0.030
        let jaw = CGFloat(mouth) * size * 0.030
        let tilt = reduceMotion ? 0 : gaze.width * 3.5

        return ZStack {
            cranium(width: size, height: headHeight)
            plateSeams(width: size, height: headHeight)
            visorRow(width: size, height: headHeight, blink: blink, t: t)
            brow(width: size, height: headHeight, t: t)
            cheekVents(width: size, height: headHeight, t: t)
            mouthAssembly(width: size, height: headHeight)
                .offset(y: jaw)
        }
        .frame(width: size, height: headHeight)
        .offset(x: gazeX, y: gazeY + CGFloat(breath) * 1.6)
        .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .shadow(color: accent.opacity(0.22 * glowStrength), radius: 26, y: 10)
    }

    /// Polished cranium: a slightly tall squircle with a brushed-silver gradient and an
    /// inner shadow so the centre reads as concave metal rather than a flat sticker.
    private func cranium(width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.44, style: .continuous)
        let light = scheme == .dark
            ? [Color(red: 0.74, green: 0.79, blue: 0.86), Color(red: 0.42, green: 0.47, blue: 0.55),
               Color(red: 0.22, green: 0.25, blue: 0.31), Color(red: 0.55, green: 0.60, blue: 0.68)]
            : [Color(white: 1.0), Color(red: 0.87, green: 0.90, blue: 0.94),
               Color(red: 0.74, green: 0.78, blue: 0.84), Color(white: 0.93)]
        return shape
            .fill(LinearGradient(colors: light, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                shape.fill(RadialGradient(colors: [Color.black.opacity(scheme == .dark ? 0.42 : 0.10), .clear],
                                          center: UnitPoint(x: 0.5, y: 0.66),
                                          startRadius: 2, endRadius: width * 0.62))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.55 : 0.9),
                                                          Color.white.opacity(0.05)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                   lineWidth: 1.2)
            }
    }

    private func plateSeams(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // Crown seam.
            Ellipse()
                .trim(from: 0.06, to: 0.44)
                .stroke(Color.black.opacity(scheme == .dark ? 0.35 : 0.14), lineWidth: 1)
                .frame(width: width * 0.80, height: height * 0.55)
                .offset(y: -height * 0.20)
            // Jaw seam.
            Ellipse()
                .trim(from: 0.56, to: 0.94)
                .stroke(Color.black.opacity(scheme == .dark ? 0.30 : 0.12), lineWidth: 1)
                .frame(width: width * 0.86, height: height * 0.72)
                .offset(y: height * 0.16)
            // Temple vents.
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.black.opacity(scheme == .dark ? 0.28 : 0.10))
                    .frame(width: width * 0.09, height: 2)
                    .offset(x: width * 0.42, y: -height * 0.05 + CGFloat(index) * 7)
                Capsule()
                    .fill(Color.black.opacity(scheme == .dark ? 0.28 : 0.10))
                    .frame(width: width * 0.09, height: 2)
                    .offset(x: -width * 0.42, y: -height * 0.05 + CGFloat(index) * 7)
            }
        }
    }

    /// The visor: one dark curved band holding two optics. The band is what makes the
    /// face read as a machine rather than a mask.
    private func visorRow(width: CGFloat, height: CGFloat, blink: Double, t: TimeInterval) -> some View {
        let bandWidth = width * 0.84
        let bandHeight = height * 0.30
        let lens = width * 0.20
        let spacing = width * 0.21

        return ZStack {
            RoundedRectangle(cornerRadius: bandHeight * 0.46, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.06),
                                              Color(red: 0.07, green: 0.09, blue: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: bandWidth, height: bandHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: bandHeight * 0.46, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
                .overlay {
                    // A slow scan line while thinking; a steady sheen otherwise.
                    RoundedRectangle(cornerRadius: bandHeight * 0.46, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, accent.opacity(scanOpacity(t: t)), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .offset(x: scanOffset(width: bandWidth, t: t))
                        .mask(RoundedRectangle(cornerRadius: bandHeight * 0.46, style: .continuous))
                        .allowsHitTesting(false)
                }

            HStack(spacing: spacing - lens) {
                optic(diameter: lens, blink: blink, t: t)
                optic(diameter: lens, blink: blink, t: t)
            }
        }
        .offset(y: -height * 0.06)
    }

    private func optic(diameter: CGFloat, blink: Double, t: TimeInterval) -> some View {
        let iris = reduceMotion ? 0.55 : 0.45 + 0.35 * abs(sin(t * 0.9))
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.black, Color(red: 0.04, green: 0.06, blue: 0.09)],
                                     center: .center, startRadius: 1, endRadius: diameter * 0.6))
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.95), accent.opacity(0.45), accent.opacity(0.10)],
                                     center: UnitPoint(x: 0.42, y: 0.38),
                                     startRadius: 0, endRadius: diameter * 0.52))
                .padding(diameter * 0.10)
                .opacity(0.55 + 0.45 * iris)
            Circle()
                .strokeBorder(accent.opacity(0.85), lineWidth: max(1, diameter * 0.035))
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: diameter * 0.16, height: diameter * 0.16)
                .offset(x: -diameter * 0.16, y: -diameter * 0.18)
                .blur(radius: 0.5)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: accent.opacity(0.7), radius: diameter * 0.34)
        .scaleEffect(y: blink, anchor: .center)
        .opacity(isFailed ? 0.75 : 1)
        .accessibilityHidden(true)
    }

    private func brow(width: CGFloat, height: CGFloat, t: TimeInterval) -> some View {
        let flicker = reduceMotion ? 1.0 : 0.72 + 0.28 * abs(sin(t * (isExecuting ? 5.0 : 1.1)))
        return Capsule()
            .fill(LinearGradient(colors: [accent.opacity(0.15), accent.opacity(0.85 * glowStrength * flicker),
                                          accent.opacity(0.15)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width * 0.52, height: max(2, height * 0.012))
            .blur(radius: 1.2)
            .offset(y: -height * 0.235)
    }

    private func cheekVents(width: CGFloat, height: CGFloat, t: TimeInterval) -> some View {
        let lit = reduceMotion ? 0.5 : 0.35 + 0.65 * abs(sin(t * 2.2))
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                let scale = state == .listening ? (0.4 + 0.6 * listeningLevel) : 1.0
                Capsule()
                    .fill(accent.opacity((0.18 + 0.30 * lit) * scale))
                    .frame(width: max(2, width * 0.018), height: height * 0.055)
                    .offset(x: -width * 0.335 + CGFloat(index) * (width * 0.030), y: height * 0.045)
                Capsule()
                    .fill(accent.opacity((0.18 + 0.30 * lit) * scale))
                    .frame(width: max(2, width * 0.018), height: height * 0.055)
                    .offset(x: width * 0.335 - CGFloat(index) * (width * 0.030), y: height * 0.045)
            }
        }
    }

    /// The mouth: seven light bars. Their heights come from the jaw opening and the
    /// current viseme, so "oh" is round and wide, "ee" is narrow, and silence closes.
    private func mouthAssembly(width: CGFloat, height: CGFloat) -> some View {
        let barCount = Viseme.barCount
        let barWidth = width * 0.028
        let gap = width * 0.016
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let openAmount = max(0, min(1, mouth))

        return HStack(spacing: gap) {
            ForEach(0..<barCount, id: \.self) { index in
                let profile = viseme.profile(forBar: index)
                let shaping = viseme.isOpen || state == .speaking ? 1.0 : 0.35
                let barHeight = max(2, height * (0.010 + 0.060 * openAmount * profile * shaping))
                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: barWidth, height: barHeight)
                    .shadow(color: accent.opacity(0.8 * (0.3 + 0.7 * openAmount)), radius: 4)
            }
        }
        .frame(width: totalWidth, height: height * 0.09, alignment: .center)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(Color.black.opacity(scheme == .dark ? 0.35 : 0.10))
                .blur(radius: 6)
        }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(accent.opacity(0.22), lineWidth: 0.8)
        }
        .offset(y: height * 0.33)
        .animation(JarvisTheme.Motion.snappy, value: openAmount)
        .animation(JarvisTheme.Motion.snappy, value: viseme)
    }

    // MARK: - Timing helpers

    private func scanOpacity(t: TimeInterval) -> Double {
        guard case .thinking = state else { return 0.10 }
        return reduceMotion ? 0.12 : 0.30
    }

    private func scanOffset(width: CGFloat, t: TimeInterval) -> CGFloat {
        guard case .thinking = state, !reduceMotion else { return 0 }
        let phase = (t * 0.55).truncatingRemainder(dividingBy: 1.0)
        return CGFloat(phase * 2 - 1) * width * 0.5
    }

    /// Deterministic blink schedule: a double blink now and then, never while error.
    static func blinkFactor(at time: TimeInterval, state: AssistantState) -> Double {
        if case .failed = state { return 0.85 }
        let period = 4.1
        let phase = time.truncatingRemainder(dividingBy: period)
        func lid(_ p: Double, start: Double, duration: Double) -> Double {
            guard p >= start, p <= start + duration else { return 1 }
            let progress = (p - start) / duration
            return 0.12 + 0.88 * abs(progress - 0.5) * 2
        }
        var value = lid(phase, start: 0.0, duration: 0.16)
        value = min(value, lid(phase, start: 0.26, duration: 0.14))   // double blink
        if case .speaking = state { return min(value, 0.94) }          // eyes relax while talking
        return value
    }
}
