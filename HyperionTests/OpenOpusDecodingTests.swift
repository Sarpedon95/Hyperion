import XCTest
@testable import Hyperion

// Fixture-based decoding tests for OpenOpus API response shapes.
// These tests verify that the DTOs decode correctly and that
// status.success == "false" is treated as a failure.

final class OpenOpusDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - /composer/list/pop.json  and  /composer/list/rec.json

    func testComposerListDecodes() throws {
        let json = """
        {
          "composers": [
            {
              "id": "196",
              "name": "Bach",
              "complete_name": "Johann Sebastian Bach",
              "epoch": "Baroque",
              "portrait": "https://example.com/bach.jpg",
              "birth": "1685-01-01",
              "death": "1750-07-28"
            }
          ],
          "status": { "success": "true", "version": "default_version", "processingtime": 0.012 }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOComposerListResponse.self, from: json)
        XCTAssertEqual(r.composers?.count, 1)
        XCTAssertEqual(r.composers?.first?.id, "196")
        XCTAssertEqual(r.composers?.first?.complete_name, "Johann Sebastian Bach")
        XCTAssertEqual(r.composers?.first?.epoch, "Baroque")
        XCTAssertTrue(r.status?.isSuccess ?? false)
    }

    // MARK: - /composer/list/name/a.json

    func testComposerListByLetterDecodes() throws {
        let json = """
        {
          "composers": [
            { "id": "2", "name": "Adams", "complete_name": "John Adams", "epoch": "21st Century",
              "portrait": null, "birth": "1947-02-15", "death": null }
          ],
          "status": { "success": "true" }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOComposerListResponse.self, from: json)
        XCTAssertEqual(r.composers?.first?.name, "Adams")
        XCTAssertNil(r.composers?.first?.death)
    }

    // MARK: - /genre/list/composer/{id}.json — genres is [String]

    func testGenreListDecodesAsStringArray() throws {
        let json = """
        {
          "genres": ["Orchestral", "Chamber", "Keyboard"],
          "status": { "success": "true" }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOGenreListResponse.self, from: json)
        XCTAssertEqual(r.genres, ["Orchestral", "Chamber", "Keyboard"])
    }

    func testGenreListEmptyArray() throws {
        let json = """
        { "genres": [], "status": { "success": "true" } }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOGenreListResponse.self, from: json)
        XCTAssertEqual(r.genres, [])
    }

    // MARK: - /omnisearch/{query}/0.json

    func testOmnisearchDecodes() throws {
        let json = """
        {
          "results": [
            { "id": "196", "name": "Johann Sebastian Bach", "type": "composer",
              "portrait": "https://example.com/bach.jpg", "epoch": "Baroque", "composer": null },
            { "id": "15076", "name": "Brandenburg Concerto No. 1", "type": "work",
              "portrait": null, "epoch": null,
              "composer": {
                "id": "196", "name": "Bach", "complete_name": "Johann Sebastian Bach",
                "epoch": "Baroque", "portrait": null, "birth": "1685-01-01", "death": "1750-07-28"
              }
            }
          ],
          "status": { "success": "true" }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOOmnisearchResponse.self, from: json)
        XCTAssertEqual(r.results?.count, 2)
        XCTAssertEqual(r.results?.first?.type, "composer")
        XCTAssertEqual(r.results?.last?.type, "work")
        XCTAssertEqual(r.results?.last?.composer?.id, "196")
    }

    // MARK: - /dyn/work/guess — works[].requested and works[].guessed

    func testGuessWorksDecodes() throws {
        let json = """
        {
          "works": [
            {
              "requested": { "composer": "Bach", "title": "Brandenburg Concerto No. 1" },
              "guessed": {
                "id": "15076",
                "title": "Brandenburg Concerto No. 1 in F major",
                "popular": "1",
                "recommended": "1",
                "genre": "Orchestral"
              }
            },
            {
              "requested": { "composer": "Beethoven", "title": "Unknown Work" },
              "guessed": null
            }
          ],
          "status": { "success": "true" }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOGuessWorksResponse.self, from: json)
        XCTAssertEqual(r.works?.count, 2)

        let first = r.works?.first
        XCTAssertEqual(first?.requested?.composer, "Bach")
        XCTAssertEqual(first?.guessed?.id, "15076")
        XCTAssertTrue(first?.guessed?.isPopular ?? false)

        let second = r.works?.last
        XCTAssertNotNil(second?.requested)
        XCTAssertNil(second?.guessed)
    }

    // MARK: - /dyn/performer/list — performers.readable and .digest

    func testPerformerListDecodes() throws {
        let json = """
        {
          "performers": {
            "readable": [
              { "name": "Herbert von Karajan", "role": "Conductor",
                "portrait": "https://example.com/karajan.jpg" },
              { "name": "Berliner Philharmoniker", "role": "Orchestra", "portrait": null }
            ],
            "digest": [
              { "name": "Herbert von Karajan", "role": "Conductor", "portrait": null }
            ]
          },
          "status": { "success": "true" }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOPerformerListResponse.self, from: json)
        XCTAssertEqual(r.performers?.readable?.count, 2)
        XCTAssertEqual(r.performers?.readable?.first?.name, "Herbert von Karajan")
        XCTAssertEqual(r.performers?.readable?.first?.role, "Conductor")
        XCTAssertEqual(r.performers?.digest?.count, 1)
    }

    // MARK: - /work/list — array shape

    func testWorkListArrayDecodes() throws {
        let json = """
        {
          "works": [
            { "id": "15076", "title": "Brandenburg Concerto No. 1", "genre": "Orchestral",
              "popular": "1", "recommended": "0" }
          ],
          "status": { "success": "true" }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOWorkListResponse.self, from: json)
        XCTAssertEqual(r.works?.count, 1)
        XCTAssertEqual(r.works?.first?.id, "15076")
    }

    // MARK: - /work/list — keyed-object shape {"w:15076": {...}}

    func testWorkListKeyedObjectDecodes() throws {
        let json = """
        {
          "w:15076": {
            "id": "15076",
            "title": "Brandenburg Concerto No. 1",
            "genre": "Orchestral",
            "popular": "1",
            "recommended": "0"
          },
          "w:15077": {
            "id": "15077",
            "title": "Brandenburg Concerto No. 2",
            "genre": "Orchestral",
            "popular": "1",
            "recommended": "0"
          },
          "status": { "success": "true" }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOWorkListResponse.self, from: json)
        XCTAssertEqual(r.works?.count, 2)
        let ids = r.works?.map(\.id).sorted() ?? []
        XCTAssertEqual(ids, ["15076", "15077"])
    }

    // MARK: - API-level failure: HTTP 200 but status.success == "false"

    func testStatusFailureIsDetected() throws {
        let json = """
        {
          "status": {
            "success": "false",
            "error": "Composer not found",
            "version": "default_version",
            "processingtime": 0.002
          }
        }
        """.data(using: .utf8)!

        let r = try decoder.decode(OOComposerListResponse.self, from: json)
        // Decoding succeeds (it's valid JSON)
        XCTAssertFalse(r.status?.isSuccess ?? true, "status.success == 'false' must report isSuccess = false")
        XCTAssertEqual(r.status?.error, "Composer not found")
        // The checkStatus call (in the service) must throw
        XCTAssertThrowsError(try throwIfFailed(r.status)) { error in
            guard case OpenOpusError.apiFailure(let msg) = error else {
                XCTFail("Expected OpenOpusError.apiFailure, got \(error)")
                return
            }
            XCTAssertEqual(msg, "Composer not found")
        }
    }

    // MARK: - Candidate scorer sanity checks

    func testComposerMismatchCappsConfidence() {
        let result = CandidateScorer.score(
            albumTitle:     "Symphony No. 5",
            albumComposer:  "Wolfgang Amadeus Mozart",
            albumArtist:    "",
            ooTitle:        "Symphony No. 5 in C minor",
            ooComposerName: "Ludwig van Beethoven",
            lmsWorkTag:     nil
        )
        XCTAssertLessThanOrEqual(result.confidence, 0.40,
            "Composer mismatch must cap confidence at 0.40, got \(result.confidence)")
    }

    func testPerfectMatchScoresHigh() {
        let result = CandidateScorer.score(
            albumTitle:     "Brandenburg Concerto No. 1",
            albumComposer:  "Johann Sebastian Bach",
            albumArtist:    "",
            ooTitle:        "Brandenburg Concerto No. 1",
            ooComposerName: "Johann Sebastian Bach",
            lmsWorkTag:     nil
        )
        XCTAssertGreaterThanOrEqual(result.confidence, 0.75,
            "Perfect composer+title match should score ≥0.75, got \(result.confidence)")
    }

    func testCatalogueConflictPenalises() {
        let result = CandidateScorer.score(
            albumTitle:     "Piano Sonata Op. 13",
            albumComposer:  "Ludwig van Beethoven",
            albumArtist:    "",
            ooTitle:        "Piano Sonata Op. 27 No. 2",
            ooComposerName: "Ludwig van Beethoven",
            lmsWorkTag:     nil
        )
        XCTAssertTrue(result.matchReason.contains("conflict"),
            "Conflicting Op numbers should be noted in matchReason: \(result.matchReason)")
    }

    func testExcerptPenaltyApplies() {
        let result = CandidateScorer.score(
            albumTitle:     "Symphony No. 9 - Highlights",
            albumComposer:  "Ludwig van Beethoven",
            albumArtist:    "",
            ooTitle:        "Symphony No. 9",
            ooComposerName: "Ludwig van Beethoven",
            lmsWorkTag:     nil
        )
        XCTAssertTrue(result.matchReason.contains("excerpt") || result.matchReason.contains("arr"),
            "Excerpt/highlight albums should have penalty in matchReason: \(result.matchReason)")
    }

    func testTitleOnlyCannotExceedMedium() {
        // Good title match but completely wrong composer
        let result = CandidateScorer.score(
            albumTitle:     "The Four Seasons",
            albumComposer:  "Max Reger",     // completely wrong
            albumArtist:    "",
            ooTitle:        "The Four Seasons",
            ooComposerName: "Antonio Vivaldi",
            lmsWorkTag:     nil
        )
        XCTAssertLessThanOrEqual(result.confidence, 0.40,
            "Title match alone with wrong composer must not exceed 0.40, got \(result.confidence)")
    }

    // MARK: - Catalogue number extraction

    func testBWVExtraction() {
        let cats = CatalogueNumber.extract(from: "Cantata BWV 147 Herz und Mund")
        XCTAssertEqual(cats["BWV"], "147")
    }

    func testOpusExtraction() {
        let cats = CatalogueNumber.extract(from: "Piano Sonata Op. 13 'Pathétique'")
        XCTAssertNotNil(cats["Op"])
    }

    func testCatalogueMatchSignal() {
        if case .match(let reason) = CatalogueNumber.signal(
            albumTitle: "Violin Sonata BWV 1001",
            ooTitle:    "Sonata for Violin Solo BWV 1001"
        ) {
            XCTAssertTrue(reason.contains("1001"))
        } else {
            XCTFail("Expected catalogue match signal for BWV 1001")
        }
    }

    func testCatalogueConflictSignal() {
        if case .conflict(let reason) = CatalogueNumber.signal(
            albumTitle: "Violin Sonata BWV 1001",
            ooTitle:    "Violin Partita BWV 1004"
        ) {
            XCTAssertTrue(reason.contains("1001") && reason.contains("1004"))
        } else {
            XCTFail("Expected catalogue conflict signal")
        }
    }

    // MARK: - Track ID filter / reorder logic (mirrors RecordingCandidateRow.playCandidate)

    func testTrackIDFilterPreservesRequestedOrder() {
        let tracks = [
            makeTrack(id: 10, title: "Mvmt I"),
            makeTrack(id: 20, title: "Mvmt II"),
            makeTrack(id: 30, title: "Mvmt III"),
        ]
        let lmsTrackIDs = [30, 10]  // reverse order of what the album returns

        let trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let ordered = lmsTrackIDs.compactMap { trackByID[$0] }

        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].id, 30, "Should respect requested order, not album order")
        XCTAssertEqual(ordered[1].id, 10)
    }

    func testTrackIDFilterSkipsMissingIDs() {
        let tracks = [
            makeTrack(id: 10, title: "Mvmt I"),
            makeTrack(id: 20, title: "Mvmt II"),
        ]
        let lmsTrackIDs = [10, 99, 20]  // 99 is not on the album

        let trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let missing = lmsTrackIDs.filter { trackByID[$0] == nil }
        let ordered = lmsTrackIDs.compactMap { trackByID[$0] }

        XCTAssertEqual(missing, [99], "Should identify exactly the missing ID")
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].id, 10)
        XCTAssertEqual(ordered[1].id, 20)
    }

    func testTrackIDFilterFallsBackToAllTracksWhenAllMissing() {
        let tracks = [
            makeTrack(id: 10, title: "Mvmt I"),
            makeTrack(id: 20, title: "Mvmt II"),
        ]
        let lmsTrackIDs = [99, 88]  // none exist on the album

        let trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let ordered = lmsTrackIDs.compactMap { trackByID[$0] }
        let tracksToPlay = ordered.isEmpty ? tracks : ordered

        XCTAssertEqual(tracksToPlay.count, 2, "Should fall back to full album when all IDs missing")
        XCTAssertEqual(tracksToPlay[0].id, 10)
        XCTAssertEqual(tracksToPlay[1].id, 20)
    }

    func testTrackIDEmptyListMeansFullAlbum() {
        let tracks = [makeTrack(id: 10, title: "Track A"), makeTrack(id: 20, title: "Track B")]
        let lmsTrackIDs: [Int] = []  // album-level candidate — no specific tracks indexed

        let trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let tracksToPlay: [Track]
        if !lmsTrackIDs.isEmpty {
            let ordered = lmsTrackIDs.compactMap { trackByID[$0] }
            tracksToPlay = ordered.isEmpty ? tracks : ordered
        } else {
            tracksToPlay = tracks
        }

        XCTAssertEqual(tracksToPlay.count, 2, "Empty lmsTrackIDs should play the full album")
    }

    // MARK: - Title normalizer

    func testNormalizerStripsKeySignature() {
        let raw = "Symphony No. 5 in C minor"
        let norm = TitleNormalizer.normalize(raw)
        XCTAssertFalse(norm.contains("minor"), "Key signature should be stripped: \(norm)")
    }

    func testNormalizerStripsCatalogueNumbers() {
        let raw = "Violin Sonata BWV 1001"
        let norm = TitleNormalizer.normalize(raw)
        // Normalizer lowercases first, so check lowercase "bwv" and the raw number.
        XCTAssertFalse(norm.contains("1001"), "Catalogue number should be stripped: \(norm)")
        XCTAssertFalse(norm.contains("bwv"),  "Catalogue label should be stripped: \(norm)")
    }

    func testWordOverlapScore() {
        let a = TitleNormalizer.normalize("Brandenburg Concerto No. 1")
        let b = TitleNormalizer.normalize("Brandenburg Concerto No. 2")
        let score = TitleNormalizer.wordOverlapScore(a, b)
        XCTAssertGreaterThan(score, 0.5, "Titles sharing 'Brandenburg Concerto' should score > 0.5")
    }

    // MARK: - Penalty detection

    func testExcerptPenaltyForHighlights() {
        XCTAssertEqual(RecordingPenalty.penalty(for: "Symphony No. 9 - Highlights"), -0.20)
    }

    func testExcerptPenaltyForExcerpt() {
        XCTAssertEqual(RecordingPenalty.penalty(for: "Piano Concerto (excerpt)"), -0.20)
    }

    func testNoPenaltyForNormalTitle() {
        XCTAssertEqual(RecordingPenalty.penalty(for: "Symphony No. 5"), 0.0)
    }

    // MARK: - Helper

    private func throwIfFailed(_ status: OOStatus?) throws {
        guard let s = status else { return }
        if !s.isSuccess {
            throw OpenOpusError.apiFailure(s.error ?? "Unknown error")
        }
    }

    private func makeTrack(id: Int, title: String) -> Track {
        Track(id: id, title: title, album: nil, albumID: nil, albumartist: nil,
              composer: nil, trackartist: nil, work: nil, duration: nil,
              tracknum: nil, discnum: nil, year: nil, coverid: nil,
              url: nil, genres: nil, isClassical: nil)
    }
}
