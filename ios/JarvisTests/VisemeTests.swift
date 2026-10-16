import XCTest
@testable import JarvisCore

/// The lip-sync maths. These run in CI on the SwiftPM suite, so the face's behaviour is
/// verified without needing a device or the Xcode build.
final class VisemeTests: XCTestCase {

    func testVowelsDecideTheShapeNotTheFirstConsonant() {
        XCTAssertEqual(Viseme(pronouncing: "Jarvis"), .openWide)      // "a", not the "j"
        XCTAssertEqual(Viseme(pronouncing: "you"), .round)            // the glide is skipped
        XCTAssertEqual(Viseme(pronouncing: "see"), .wide)             // "e", not the "s"
        XCTAssertEqual(Viseme(pronouncing: "ship"), .wide)            // "i"
        XCTAssertEqual(Viseme(pronouncing: "stop"), .round)           // "o", not the "s"
        XCTAssertEqual(Viseme(pronouncing: "fish"), .wide)            // the vowel wins
    }

    func testWordsWithNoVowelFallBackToConsonantShapes() {
        XCTAssertEqual(Viseme(pronouncing: "hmm"), .closed)           // closed hum
        XCTAssertEqual(Viseme(pronouncing: "psst"), .closed)          // lips together
        XCTAssertEqual(Viseme(pronouncing: "shh"), .fricative)        // teeth and air
        XCTAssertEqual(Viseme(pronouncing: "12345"), .mid)            // numbers get a neutral shape
    }

    func testClosedShapesNeverDisappearEntirely() {
        // A mouth that vanishes looks broken; the closed shape keeps a thin line.
        for viseme in Viseme.allCases {
            for bar in 0..<Viseme.barCount {
                let profile = viseme.profile(forBar: bar)
                XCTAssertGreaterThan(profile, 0, "\(viseme) bar \(bar) must keep some height")
                XCTAssertLessThanOrEqual(profile, 1.0, "\(viseme) bar \(bar) must stay normalised")
            }
        }
    }

    func testOpenWideIsTallerInTheMiddleAndWideLiftsTheCorners() {
        XCTAssertGreaterThan(Viseme.openWide.profile(forBar: 3), Viseme.openWide.profile(forBar: 0))
        XCTAssertGreaterThan(Viseme.wide.profile(forBar: 0), Viseme.wide.profile(forBar: 3))
    }

    func testJawOpeningIsBoundedAndVowelDriven() {
        let silent = Viseme.opening(for: "shh")
        let vowelHeavy = Viseme.opening(for: "aha")
        XCTAssertGreaterThanOrEqual(silent, 0.0)
        XCTAssertLessThanOrEqual(vowelHeavy, 1.0)
        XCTAssertGreaterThan(vowelHeavy, silent, "vowels must open the jaw more than consonants")
        // Long utterances must not pin the mouth open.
        XCTAssertLessThanOrEqual(Viseme.opening(for: "a" + String(repeating: "a", count: 40)), 1.0)
        // Every word moves the mouth a little, so silence never looks like a freeze.
        XCTAssertGreaterThan(Viseme.opening(for: "t"), 0.0)
        XCTAssertGreaterThan(Viseme.opening(for: "12345"), 0.0)
    }

    func testPunctuationClosesTheMouthDown() {
        XCTAssertLessThan(Viseme.opening(for: "ok."), Viseme.opening(for: "ok"))
    }
}
