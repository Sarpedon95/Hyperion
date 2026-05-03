import Foundation

/// App-local recently-played history.
///
/// LMS only records plays that go through the server-side player. Hyperion plays
/// streams directly with AVPlayer, so we keep a small per-server album history
/// locally and merge it with whatever LMS can report.
@MainActor
final class PlaybackHistoryStore {
    static let shared = PlaybackHistoryStore()

    private struct Entry: Codable, Hashable {
        let album: Album
        let playedAt: Date
    }

    // PERF: create encoder/decoder once; they carry non-trivial setup.
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

    /// In-memory cache so recordPlayback() doesn't round-trip through
    /// UserDefaults JSON decode+sort+encode on every track start.
    private var cachedEntries: [Entry]?

    private init() {}

    func recentlyPlayedAlbums(limit: Int = 20) -> [Album] {
        Array(loadEntries().map(\.album).prefix(limit))
    }

    func recordPlayback(of track: Track, playedAt: Date = Date()) {
        guard let album = makeAlbum(from: track) else { return }

        // Prepend, deduplicate by album id, trim, persist.
        var entries = loadEntries().filter { $0.album.id != album.id }
        entries.insert(Entry(album: album, playedAt: playedAt), at: 0)
        if entries.count > maxStoredAlbums {
            entries = Array(entries.prefix(maxStoredAlbums))
        }
        saveEntries(entries)
    }

    func clear() {
        cachedEntries = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Called when the active server URL changes so the in-memory cache is not
    /// carried over to a different server's history slot.
    func invalidateCache() {
        cachedEntries = nil
    }

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

    private func loadEntries() -> [Entry] {
        if let cached = cachedEntries { return cached }
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? decoder.decode([Entry].self, from: data) else {
            cachedEntries = []
            return []
        }
        let sorted = decoded.sorted { $0.playedAt > $1.playedAt }
        cachedEntries = sorted
        return sorted
    }

    private func saveEntries(_ entries: [Entry]) {
        cachedEntries = entries
        guard let data = try? encoder.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private var storageKey: String {
        let server = LyrionAPI.shared.baseURL.isEmpty ? "default" : LyrionAPI.shared.baseURL
        // PERF: alphanumerics is a superset of what we need, so the percent-
        // encoding never makes a key longer than needed.
        let encoded = server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "default"
        return "com.hyperion.localPlaybackHistory.v1.\(encoded)"
    }
}
