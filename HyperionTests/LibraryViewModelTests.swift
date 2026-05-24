import XCTest
@testable import Hyperion

// Tests for the LibraryViewModel.resolveTracks helper added in audit phase
// 1. Only the in-memory fast path is exercised here — the server fallback
// (getSong(id:)) requires a live LMS and is left for integration tests.

@MainActor
final class LibraryViewModelResolveTracksTests: XCTestCase {

    private func makeTrack(id: Int, title: String = "T") -> Track {
        Track(
            id: id, title: title, album: nil, albumID: nil, albumartist: nil,
            composer: nil, trackartist: nil, work: nil, duration: nil,
            tracknum: nil, discnum: nil, year: nil, coverid: nil, url: nil,
            genres: nil, isClassical: nil
        )
    }

    func testResolveTracksReturnsEmptyForEmptyInput() async {
        let result = await LibraryViewModel.shared.resolveTracks(ids: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testResolveTracksFromInMemoryLibrary() async {
        // Seed the singleton with three tracks.
        let vm = LibraryViewModel.shared
        let originalSongs = vm.songs
        defer { vm.songs = originalSongs }
        vm.songs = [
            makeTrack(id: 100, title: "Alpha"),
            makeTrack(id: 200, title: "Bravo"),
            makeTrack(id: 300, title: "Charlie"),
        ]
        let resolved = await vm.resolveTracks(ids: [300, 100, 200])
        XCTAssertEqual(resolved.map(\.id), [300, 100, 200],
                       "Order of input IDs must be preserved")
        XCTAssertEqual(resolved.map(\.title), ["Charlie", "Alpha", "Bravo"])
    }

    func testResolveTracksDeduplicatesByID() async {
        // Same ID twice → present twice in output (the helper preserves
        // input order; deduplication is a caller concern). Verify that
        // contract explicitly so a future "silent dedup" change is caught.
        let vm = LibraryViewModel.shared
        let originalSongs = vm.songs
        defer { vm.songs = originalSongs }
        vm.songs = [makeTrack(id: 7, title: "Repeat")]
        let resolved = await vm.resolveTracks(ids: [7, 7, 7])
        XCTAssertEqual(resolved.count, 3)
        XCTAssertEqual(Set(resolved.map(\.id)), [7])
    }
}
