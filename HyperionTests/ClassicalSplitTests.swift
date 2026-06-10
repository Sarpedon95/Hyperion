import XCTest
@testable import Hyperion

// Locks the canonical rule that drives the complete Home ⇄ Classical data
// split: content is "classical" iff its LMS genre tag contains the substring
// "classical" (case-/diacritic-insensitive), with a conservative fallback to
// the server `isClassical` flag / composer credit where no genre tag exists.

final class ClassicalSplitTests: XCTestCase {

    func testGenreRuleMatchesSubstringCaseInsensitively() {
        XCTAssertTrue(ClassicalMode.genreIsClassical("Classical"))
        XCTAssertTrue(ClassicalMode.genreIsClassical("classical"))
        XCTAssertTrue(ClassicalMode.genreIsClassical("Modern Classical"))
        XCTAssertTrue(ClassicalMode.genreIsClassical("Rock, Classical Crossover"),
                      "Comma-separated multi-genre strings match if any component is classical")
        XCTAssertFalse(ClassicalMode.genreIsClassical("Hip-Hop"))
        XCTAssertFalse(ClassicalMode.genreIsClassical("Electronic"))
        XCTAssertFalse(ClassicalMode.genreIsClassical(nil))
        XCTAssertFalse(ClassicalMode.genreIsClassical(""))
    }

    func testTrackIsClassicalContentPrefersGenreTag() {
        XCTAssertTrue(makeTrack(genres: "Classical").isClassicalContent)
        XCTAssertFalse(makeTrack(genres: "Jazz").isClassicalContent)
        // Server flag still counts when no genre tag is present.
        XCTAssertTrue(makeTrack(genres: nil, isClassical: 1).isClassicalContent)
        XCTAssertFalse(makeTrack(genres: nil, isClassical: nil).isClassicalContent)
    }

    func testAlbumIsClassicalContentFallsBackToFlagAndComposer() {
        XCTAssertTrue(makeAlbum(genres: "Classical").isClassicalContent)
        XCTAssertTrue(makeAlbum(isClassical: 1).isClassicalContent)
        XCTAssertTrue(makeAlbum(composer: "Ludwig van Beethoven").isClassicalContent)
        XCTAssertFalse(makeAlbum().isClassicalContent)
        XCTAssertFalse(makeAlbum(genres: "Pop").isClassicalContent)
    }

    func testGenreNameClassification() {
        XCTAssertTrue(Genre(id: 1, name: "Classical").isClassicalContent)
        XCTAssertTrue(Genre(id: 2, name: "Contemporary Classical").isClassicalContent)
        XCTAssertFalse(Genre(id: 3, name: "Electronic").isClassicalContent)
    }

    // MARK: - Helpers

    private func makeTrack(genres: String?, isClassical: Int? = nil) -> Track {
        Track(
            id: 1, title: "T", album: nil, albumID: nil, albumartist: nil,
            composer: nil, trackartist: nil, work: nil, duration: nil,
            tracknum: nil, discnum: nil, year: nil, coverid: nil, url: nil,
            genres: genres, isClassical: isClassical
        )
    }

    private func makeAlbum(genres: String? = nil, isClassical: Int? = nil, composer: String? = nil) -> Album {
        Album(
            id: 1, album: "A", artist: nil, year: nil, artwork_track_id: nil,
            composer: composer, isClassical: isClassical, genres: genres
        )
    }
}
