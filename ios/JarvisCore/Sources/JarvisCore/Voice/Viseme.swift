import Foundation

/// Lip shapes, derived from the letters actually being spoken.
///
/// Lives in the engine (not the view layer) so the mapping is covered by the SwiftPM
/// test suite that runs in CI, rather than only compiling on Apple platforms.
///
/// The app never pretends to run phonetic speech recognition: AVSpeechSynthesizer
/// reports which characters of the utterance it is voicing, and this type turns that
/// word into a coarse mouth shape. That is an honest approximation — the mouth is
/// driven by real speech events, and it is documented as an approximation rather than
/// presented as accurate phoneme tracking.
public enum Viseme: String, CaseIterable, Sendable {
    case rest        // closed / neutral
    case openWide    // "ah", "a"
    case round       // "oh", "oo", "w"
    case wide        // "ee", "i", "y"
    case mid         // "eh", "e"
    case closed      // "m", "b", "p" — the lips actually close
    case fricative   // "f", "v", "s", "z", "th"

    /// Seven light bars make up the mouth; profiles give each bar a relative height.
    public static let barCount = 7

    /// Relative height (0…1) of a mouth bar in this shape — the widest bar is 1.
    public func profile(forBar index: Int) -> Double {
        let centre = Double(Self.barCount - 1) / 2
        let distance = abs(Double(index) - centre) / centre       // 0 at centre, 1 at edge

        switch self {
        case .rest:       return 0.25
        case .closed:     return 0.15
        case .openWide:   return 1.0 - 0.35 * distance * distance  // round, tallest centre
        case .round:      return 0.78 - 0.10 * distance
        case .wide:       return 0.34 + 0.10 * distance            // corners lift
        case .mid:        return 0.62 - 0.28 * distance * distance
        case .fricative:  return 0.22 + 0.08 * (1 - distance)
        }
    }

    /// Whether the shape should be visible at all when idle.
    public var isOpen: Bool { self != .rest && self != .closed }

    /// The mouth shape for a spoken word.
    ///
    /// Vowels decide it: a mouth reads a word by its vowel, which is why "Jarvis" is an
    /// open "ah" shape and not the "j" it starts with. Consonant shapes are only used
    /// when the word has no vowel at all.
    public init(pronouncing word: String) {
        let lowered = word.lowercased()
        let letters = lowered.filter { $0.isLetter }
        guard !letters.isEmpty else { self = .mid; return }

        let vowels = "aeiouáàäéèíóöúü"
        let hasVowel = letters.contains { vowels.contains($0) || ($0 == "y" && letters.first != "y") }

        if hasVowel {
            for (index, character) in letters.enumerated() {
                switch character {
                case "a", "á", "à", "ä": self = .openWide; return
                case "o", "ó", "ö", "u", "ú", "ü", "w": self = .round; return
                case "e", "é", "è", "i", "í": self = .wide; return
                case "y" where index > 0: self = .wide; return       // "system", not "you"
                default: continue
                }
            }
            self = .mid
            return
        }

        // No vowel: hums and plosives close the lips, sibilants bare the teeth.
        let first = letters.first!
        if "mbp".contains(first) { self = .closed; return }
        if letters.allSatisfy({ "hmn".contains($0) }) { self = .closed; return }
        if "fvszthcx".contains(first) { self = .fricative; return }
        self = .mid
    }

    /// How far the jaw opens for a word (0…1): vowel weight plus a length bonus, with a
    /// floor so even short words move the mouth a little.
    public static func opening(for word: String) -> Double {
        let lowered = word.lowercased()
        var weight = 0.32
        var vowelCount = 0
        for character in lowered {
            switch character {
            case "a": weight += 0.45; vowelCount += 1
            case "o", "u": weight += 0.38; vowelCount += 1
            case "e", "i", "y": weight += 0.24; vowelCount += 1
            case "m", "n", "b", "p": weight += 0.10; vowelCount += 1
            default: continue
            }
        }
        // Long words never lock the jaw open; punctuation-heavy tokens close it down.
        let lengthFactor = min(1.0, Double(lowered.count) / 7.0)
        let punctuation = lowered.filter { !$0.isLetter }.count
        let penalty = Double(punctuation) * 0.18
        let value = (weight * (0.75 + 0.25 * lengthFactor)) - penalty
        return max(vowelCount == 0 ? 0.10 : 0.22, min(1.0, value))
    }
}
