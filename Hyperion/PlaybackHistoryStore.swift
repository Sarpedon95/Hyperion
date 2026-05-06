import Foundation

/// App-local playback history: recently-played albums plus per-artist and
/// per-genre play counts derived from individual track plays.
@MainActor
final class PlaybackHistoryStore: ObservableObject {
    static let shared = PlaybackHistoryStore()

    private struct AlbumEntry: Codable, Hashable {
        let album: Album
        let playedAt: Date
    }

    private struct HistoryPayload: Codable {
        var entries: [AlbumEntry]
        var artistCounts: [String: Int]
        var genreCounts:  [String: Int]
    }

    @Published private(set) var artistPlayCounts: [String: Int] = [:]
    @Published private(set) var genrePlayCounts:  [String: Int] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let maxStoredAlbums = 60
    private var cachedEntries: [AlbumEntry]?

    private init() {
        let p = loadPayload()
        artistPlayCounts = p.artistCounts
        genrePlayCounts  = p.genreCounts
        cachedEntries    = p.entries
    }

    // MARK: - Public API

    func recentlyPlayedAlbums(limit: Int = 20) -> [Album] {
        Array(loadEntries().map(\.album).prefix(limit))
    }

    func recordPlayback(of track: Track, playedAt: Date = Date()) {
        // Album entry
        if let album = makeAlbum(from: track) {
            var entries = loadEntries().filter { $0.album.id != album.id }
            entries.insert(AlbumEntry(album: album, playedAt: playedAt), at: 0)
            if entries.count > maxStoredAlbums { entries = Array(entries.prefix(maxStoredAlbums)) }
            cachedEntries = entries
        }

        // Artist count
        if let artist = (track.trackartist ?? track.albumartist ?? track.composer)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            artistPlayCounts[artist, default: 0] += 1
        }

        // Genre count — genres field can be a comma-separated list
        if let genresStr = track.genres, !genresStr.isEmpty {
            let parts = genresStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for genre in parts where !genre.isEmpty {
                genrePlayCounts[genre, default: 0] += 1
            }
        }

        savePayload()
    }

    func clear() {
        cachedEntries    = nil
        artistPlayCounts = [:]
        genrePlayCounts  = [:]
        try? FileManager.default.removeItem(at: fileURL())
    }

    func invalidateCache() {
        cachedEntries = nil
    }

    // MARK: - Private helpers

    private func makeAlbum(from track: Track) -> Album? {
        guard let albumID = track.albumID,
              let title = track.album?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return Album(
            id:               albumID,
            album:            title,
            artist:           track.albumartist ?? track.trackartist,
            year:             track.year,
            artwork_track_id: track.coverid,
            composer:         track.composer,
            isClassical:      track.isClassical
        )
    }

    private func loadEntries() -> [AlbumEntry] {
        if let cached = cachedEntries { return cached }
        let p = loadPayload()
        cachedEntries = p.entries
        return p.entries
    }

    private func fileURL() -> URL {
        AppFiles.url(for: "hyperion_history_\(encodedServer).json")
    }

    private var encodedServer: String {
        let server = LyrionAPI.shared.baseURL.isEmpty ? "default" : LyrionAPI.shared.baseURL
        return server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "default"
    }

    private func loadPayload() -> HistoryPayload {
        let url = fileURL()

        // One-time migration: read old UserDefaults key, write to file
        let legacyKey = "com.hyperion.localPlaybackHistory.v1.\(encodedServer)"
        if !FileManager.default.fileExists(atPath: url.path),
           let data = UserDefaults.standard.data(forKey: legacyKey),
           let oldEntries = try? decoder.decode([AlbumEntry].self, from: data) {
            let payload = HistoryPayload(entries: oldEntries, artistCounts: [:], genreCounts: [:])
            if let d = try? encoder.encode(payload) { try? d.write(to: url, options: .atomicWrite) }
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return payload
        }

        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(HistoryPayload.self, from: data) else {
            return HistoryPayload(entries: [], artistCounts: [:], genreCounts: [:])
        }
        let sorted = HistoryPayload(
            entries:      payload.entries.sorted { $0.playedAt > $1.playedAt },
            artistCounts: payload.artistCounts,
            genreCounts:  payload.genreCounts
        )
        return sorted
    }

    private func savePayload() {
        let payload = HistoryPayload(
            entries:      cachedEntries ?? [],
            artistCounts: artistPlayCounts,
            genreCounts:  genrePlayCounts
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL(), options: .atomicWrite)
    }
}
