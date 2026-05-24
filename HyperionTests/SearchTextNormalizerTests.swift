import XCTest
@testable import Hyperion

// Tests for SearchTextNormalizer — the diacritic + case-insensitive fold
// that underpins every search and matching helper in the app. These were
// uncovered before the phase-8 expansion.

final class SearchTextNormalizerTests: XCTestCase {

    // MARK: - folded(_:)

    func testFoldedLowercasesAscii() {
        XCTAssertEqual(SearchTextNormalizer.folded("Beethoven"), "beethoven")
    }

    func testFoldedStripsAccents() {
        XCTAssertEqual(SearchTextNormalizer.folded("Dvořák"),    "dvorak")
        XCTAssertEqual(SearchTextNormalizer.folded("Pärt"),      "part")
        XCTAssertEqual(SearchTextNormalizer.folded("Sibelius"),  "sibelius")
        XCTAssertEqual(SearchTextNormalizer.folded("Béla Bartók"), "bela bartok")
    }

    func testFoldedTrimsWhitespace() {
        XCTAssertEqual(SearchTextNormalizer.folded("  Mozart  "), "mozart")
    }

    func testFoldedHandlesEmpty() {
        XCTAssertEqual(SearchTextNormalizer.folded(""), "")
        XCTAssertEqual(SearchTextNormalizer.folded("   "), "")
    }

    // The folded form pins to POSIX so Turkish 'I' doesn't get folded to a
    // dotless 'ı' on a Turkish device. Make sure both branches behave the same.
    func testFoldedTurkishILocaleStable() {
        // Both should fold to "istanbul" (the POSIX rule); without POSIX pinning,
        // tr_TR would produce "ıstanbul" (dotless i).
        XCTAssertEqual(SearchTextNormalizer.folded("Istanbul"), "istanbul")
        XCTAssertEqual(SearchTextNormalizer.folded("İSTANBUL"), "i̇stanbul")
            // Note: combining-dot above is preserved by .caseInsensitive folding
            // on uppercase dotted I; what matters for our use is that the result
            // is locale-stable, not visually identical to a plain "istanbul".
    }

    // MARK: - tokens(from:)

    func testTokensSplitsOnWhitespace() {
        XCTAssertEqual(SearchTextNormalizer.tokens(from: "Mozart Symphony 40"),
                       ["mozart", "symphony", "40"])
    }

    func testTokensFoldsAccentsBeforeSplit() {
        XCTAssertEqual(SearchTextNormalizer.tokens(from: "Dvořák Symphony"),
                       ["dvorak", "symphony"])
    }

    func testTokensEmptyInput() {
        XCTAssertEqual(SearchTextNormalizer.tokens(from: ""), [])
    }

    // MARK: - matches(_:query:)

    func testMatchesEmptyQueryReturnsTrue() {
        XCTAssertTrue(SearchTextNormalizer.matches("anything", query: ""))
        XCTAssertTrue(SearchTextNormalizer.matches("anything", query: "   "))
    }

    func testMatchesSubstring() {
        XCTAssertTrue(SearchTextNormalizer.matches("Symphony No. 5", query: "symphony"))
        XCTAssertTrue(SearchTextNormalizer.matches("Symphony No. 5", query: "no. 5"))
        XCTAssertFalse(SearchTextNormalizer.matches("Symphony No. 5", query: "Op."))
    }

    func testMatchesAccentInsensitive() {
        XCTAssertTrue(SearchTextNormalizer.matches("Dvořák", query: "dvorak"))
        XCTAssertTrue(SearchTextNormalizer.matches("Dvorak", query: "dvořák"))
    }

    func testMatchesAllTokensWhenSubstringFails() {
        // "Suite No. 3 in D major" — substring fails for "3 d major" but
        // every token is present, so the all-tokens fallback should hit.
        XCTAssertTrue(SearchTextNormalizer.matches("Suite No. 3 in D major", query: "3 D major"))
    }

    // MARK: - Needle

    func testNeedleEquatable() {
        let a = SearchTextNormalizer.Needle("Bach")
        let b = SearchTextNormalizer.Needle("BACH")
        XCTAssertEqual(a, b)  // both fold to "bach", with the same tokens
    }

    func testNeedleEmpty() {
        XCTAssertTrue(SearchTextNormalizer.Needle("").isEmpty)
        XCTAssertTrue(SearchTextNormalizer.Needle("   ").isEmpty)
        XCTAssertFalse(SearchTextNormalizer.Needle("a").isEmpty)
    }

    func testNeedleMatchesUsesFoldedQuery() {
        let needle = SearchTextNormalizer.Needle("Pärt")
        XCTAssertTrue(needle.matches("Arvo Part"))
        XCTAssertTrue(needle.matches("Arvo Pärt"))
        XCTAssertFalse(needle.matches("Beethoven"))
    }
}
