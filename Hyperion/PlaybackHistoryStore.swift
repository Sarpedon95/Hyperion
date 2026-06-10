import Foundation

/// App-local playback history: recently-played albums plus per-artist and
/// per-genre play counts derived from individual track plays.
@MainActor
final class PlaybackHistoryStore: ObservableObject {
    static let shared = PlaybackHistoryStore()

    private struct AlbumEntry: Codable, Hashable {
        let album: Album
        let playedAt: Date
        /// Genre category captured at play time, so the Home and Classical tabs
        /// can query their slice without re-deriving it from incomplete album
        /// metadata. Derived from the played track's genre tag.
        let isClassical: Bool

        init(album: Album, playedAt: Date, isClassical: Bool) {
            self.album = album
            self.playedAt = playedAt
            self.isClassical = isClassical
        }

        // Backward-compatible decode: entries written before the split lack the
        // flag — fall back to classifying the stored album so existing history
        // is partitioned sensibly instead of wiping the file on upgrade.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            album = try c.decode(Album.self, forKey: .album)
            playedAt = try c.decode(Date.self, forKey: .playedAt)
            isClassical = (try? c.decode(Bool.self, forKey: .isClassical)) ?? album.isClassicalContent
        }
    }

    struct TrackPlayRecord: Codable, Identifiable {
        var id: Int { trackID }
        let trackID: Int
        let title: String
        let artist: String
        let album: String
        let coverid: String?
        var playCount: Int
        var lastPlayedAt: Date
    }

    private struct HistoryPayload: Codable {
        var entries: [AlbumEntry]
        var artistCounts: [String: Int]
        var genreCounts:  [String: Int]
        var trackRecords: [Int: TrackPlayRecord]
        var dailySeconds: [String: Double]
        var hourBuckets:  [Int: Double]    // hour 0–23 → cumulative seconds

        init(entries: [AlbumEntry], artistCounts: [String: Int], genreCounts: [String: Int],
             trackRecords: [Int: TrackPlayRecord], dailySeconds: [String: Double], hourBuckets: [Int: Double]) {
            self.entries      = entries
            self.artistCounts = artistCounts
            self.genreCounts  = genreCounts
            self.trackRecords = trackRecords
            self.dailySeconds = dailySeconds
            self.hourBuckets  = hourBuckets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries      = try c.decode([AlbumEntry].self, forKey: .entries)
            artistCounts = try c.decode([String: Int].self, forKey: .artistCounts)
            genreCounts  = try c.decode([String: Int].self, forKey: .genreCounts)
            trackRecords = (try? c.decode([Int: TrackPlayRecord].self, forKey: .trackRecords)) ?? [:]
            dailySeconds = (try? c.decode([String: Double].self, forKey: .dailySeconds)) ?? [:]
            hourBuckets  = (try? c.decode([Int: Double].self, forKey: .hourBuckets)) ?? [:]
        }
    }

    @Published private(set) var artistPlayCounts: [String: Int] = [:]
    @Published private(set) var genrePlayCounts:  [String: Int] = [:]
    @Published private(set) var trackPlayRecords: [Int: TrackPlayRecord] = [:]
    /// ISO date string (yyyy-MM-dd) → seconds listened that day.
    @Published private(set) var dailySeconds: [String: Double] = [:]
    /// Hour-of-day (0–23) → cumulative seconds listened.
    @Published private(set) var hourBuckets:  [Int: Double] = [:]

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

    static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private init() {
        let p = loadPayload()
        artistPlayCounts = p.artistCounts
        genrePlayCounts  = p.genreCounts
        trackPlayRecords = p.trackRecords
        dailySeconds     = p.dailySeconds
        hourBuckets      = p.hourBuckets
        cachedEntries    = p.entries
    }

    // MARK: - Public API

    /// Recently-played albums. When `classical` is nil the full history is
    /// returned; otherwise only the matching genre category — this is how the
    /// Home (`classical: false`) and Classical (`classical: true`) tabs stay
    /// fully separated at the data layer.
    func recentlyPlayedAlbums(classical: Bool? = nil, limit: Int = 20) -> [Album] {
        var entries = loadEntries()
        if let classical {
            entries = entries.filter { $0.isClassical == classical }
        }
        return Array(entries.map(\.album).prefix(limit))
    }

    func recordPlayback(of track: Track, playedAt: Date = Date()) {
        let trackIsClassical = track.isClassicalContent

        // Album entry
        if let album = makeAlbum(from: track) {
            var entries = loadEntries().filter { $0.album.id != album.id }
            entries.insert(AlbumEntry(album: album, playedAt: playedAt, isClassical: trackIsClassical), at: 0)
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

        // Daily listening time (heatmap)
        let secs = track.duration ?? 0
        if secs > 0 {
            let dayStr = Self.dayKey.string(from: playedAt)
            dailySeconds[dayStr, default: 0] += secs
            let hour = Calendar.current.component(.hour, from: playedAt)
            hourBuckets[hour, default: 0] += secs
        }

        // Per-track play count
        let artistName = (track.trackartist ?? track.albumartist ?? track.composer ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if var rec = trackPlayRecords[track.id] {
            rec.playCount += 1
            rec.lastPlayedAt = playedAt
            trackPlayRecords[track.id] = rec
        } else {
            trackPlayRecords[track.id] = TrackPlayRecord(
                trackID:      track.id,
                title:        track.title,
                artist:       artistName,
                album:        track.album ?? "",
                coverid:      track.coverid,
                playCount:    1,
                lastPlayedAt: playedAt
            )
        }

        savePayload()
    }

    func mostPlayedTracks(limit: Int = 20) -> [TrackPlayRecord] {
        Array(trackPlayRecords.values
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit))
    }

    func playCount(for trackID: Int) -> Int {
        trackPlayRecords[trackID]?.playCount ?? 0
    }

    func clear() {
        cachedEntries    = nil
        artistPlayCounts = [:]
        genrePlayCounts  = [:]
        trackPlayRecords = [:]
        dailySeconds     = [:]
        hourBuckets      = [:]
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
            isClassical:      track.isClassical,
            genres:           track.genres
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
            let payload = HistoryPayload(entries: oldEntries, artistCounts: [:], genreCounts: [:],
                                         trackRecords: [:], dailySeconds: [:], hourBuckets: [:])
            if let d = try? encoder.encode(payload) { try? d.write(to: url, options: .atomicWrite) }
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return payload
        }

        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(HistoryPayload.self, from: data) else {
            return HistoryPayload(entries: [], artistCounts: [:], genreCounts: [:],
                                   trackRecords: [:], dailySeconds: [:], hourBuckets: [:])
        }
        return HistoryPayload(
            entries:      payload.entries.sorted { $0.playedAt > $1.playedAt },
            artistCounts: payload.artistCounts,
            genreCounts:  payload.genreCounts,
            trackRecords: payload.trackRecords,
            dailySeconds: payload.dailySeconds,
            hourBuckets:  payload.hourBuckets
        )
    }

    private func savePayload() {
        let payload = HistoryPayload(
            entries:      cachedEntries ?? [],
            artistCounts: artistPlayCounts,
            genreCounts:  genrePlayCounts,
            trackRecords: trackPlayRecords,
            dailySeconds: dailySeconds,
            hourBuckets:  hourBuckets
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL(), options: .atomicWrite)
    }
}
