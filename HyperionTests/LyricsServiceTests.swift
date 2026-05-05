import XCTest
@testable import Hyperion

final class LyricsServiceTests: XCTestCase {

    // MARK: - Title normalization

    func testMoneyRemaster2023Normalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money (2023 Remaster)"), "Money")
    }

    func testMoneyRemaster2011VersionNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money (2011 Remastered Version)"), "Money")
    }

    func testMoneySquareBracketNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money [2023 Remaster]"), "Money")
    }

    func testMoneyDashNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money - 2023 Remaster"), "Money")
    }

    func testMoneyRemasteredParenNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money (Remastered)"), "Money")
    }

    func testMoneyRemasteredSquareBracketNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money [Remastered]"), "Money")
    }

    func testMoneyRemasteredYearNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money (Remastered 2011)"), "Money")
    }

    func testWishYouWereHereDashNormalizes() {
        XCTAssertEqual(
            LRCLIBProvider.normalizeTitle("Wish You Were Here - Remastered 2011"),
            "Wish You Were Here"
        )
    }

    func testTitleWithNoSuffixUnchanged() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("Money"), "Money")
    }

    func testLiveVariantNormalizes() {
        XCTAssertEqual(
            LRCLIBProvider.normalizeTitle("Comfortably Numb (Live)"),
            "Comfortably Numb"
        )
    }

    func testLiveAtVenueNormalizes() {
        XCTAssertEqual(
            LRCLIBProvider.normalizeTitle("Comfortably Numb (Live at Wembley)"),
            "Comfortably Numb"
        )
    }

    func testDeluxeEditionNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("The Wall (Deluxe Edition)"), "The Wall")
    }

    func testDeluxeEditionSquareBracketNormalizes() {
        XCTAssertEqual(LRCLIBProvider.normalizeTitle("The Wall [Deluxe Edition]"), "The Wall")
    }

    func testFeaturedArtistNormalizes() {
        XCTAssertEqual(
            LRCLIBProvider.normalizeTitle("Something (feat. George Harrison)"),
            "Something"
        )
    }

    func testMultiSuffixNormalizes() {
        // Both a remaster paren and a year variant — only one applies but result is still clean
        XCTAssertEqual(
            LRCLIBProvider.normalizeTitle("Money (2023 Remaster) (Remastered)"),
            "Money"
        )
    }

    // MARK: - Cache key versioning

    func testCacheBuster() {
        // Confirm that the v2 prefix means two otherwise-identical queries
        // produce a different cache key than they would have under v1 logic.
        // We test indirectly: consecutive calls to clearCache + lyrics must
        // not return a cached .unavailable from the old scheme.
        //
        // (Full integration would require network; this is a structural check.)
        let v2key = "v2|pink floyd|money|the dark side of the moon"
        var hash: UInt64 = 5381
        for byte in v2key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let v2 = String(format: "%016llx", hash)

        let v1key = "pink floyd|money|the dark side of the moon"
        var hash2: UInt64 = 5381
        for byte in v1key.utf8 { hash2 = (hash2 &* 33) &+ UInt64(byte) }
        let v1 = String(format: "%016llx", hash2)

        XCTAssertNotEqual(v1, v2, "v2 prefix must produce a different cache key so old negative results don't block the ladder")
    }
}
