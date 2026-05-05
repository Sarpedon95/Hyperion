import Foundation

// Fetches lyrics from LRCLIB (https://lrclib.net) — a free, public, community-
// maintained database that provides synced (LRC-format) and plain lyrics.
// No authentication required. Responses cached to disk so repeated opens
// are instant.

// MARK: - Data types

struct LyricsLine: Identifiable, Equatable {
    let id: UUID
    let time: TimeInterval   // seconds from track start
    let text: String

    init(time: TimeInterval, text: String) {
        self.id   = UUID()
        self.time = time
        self.text = text
    }
}

enum LyricsResult {
    case synced([LyricsLine])   // time-stamped lines from LRC data
    case plain(String)          // full text, no timestamps
    case instrumental           // track is flagged instrumental by LRCLIB
    case unavailable            // no lyrics found
}

// MARK: - Service

@MainActor
final class LyricsService {

    static let shared = LyricsService()
    private init() {}

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public API

    /// Fetch lyrics for a track. Returns cached result instantly when available.
    func lyrics(
        artistName: String,
        trackName:  String,
        albumName:  String?,
        duration:   TimeInterval?
    ) async -> LyricsResult {
        let key = cacheKey(artist: artistName, track: trackName, album: albumName ?? "")
        if let cached = loadFromCache(key: key) { return cached }

        let result = await fetchFromLRCLIB(
            artist:   artistName,
            track:    trackName,
            album:    albumName,
            duration: duration
        )
        // Don't cache "unavailable" — the track might appear later in the DB.
        if case .unavailable = result {} else {
            saveToCache(result, key: key)
        }
        return result
    }

    // MARK: - LRCLIB fetch

    private func fetchFromLRCLIB(
        artist:   String,
        track:    String,
        album:    String?,
        duration: TimeInterval?
    ) async -> LyricsResult {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name",  value: track)
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        components.queryItems = items

        guard let url = components.url else { return .unavailable }
        var request = URLRequest(url: url)
        request.setValue(
            "Hyperion/1.0 (iOS classical music player; contact via lrclib.net)",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 404 { return .unavailable }
            guard http.statusCode == 200 else { return .unavailable }

            let payload = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            if payload.instrumental == true { return .instrumental }

            if let synced = payload.syncedLyrics, !synced.isEmpty {
                let lines = parseLRC(synced)
                if !lines.isEmpty { return .synced(lines) }
            }
            if let plain = payload.plainLyrics, !plain.isEmpty {
                return .plain(plain)
            }
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    // MARK: - LRC parser

    // LRC format: "[mm:ss.xx] text\n[mm:ss.xx] text\n..."
    // Some sources omit hundredths: "[mm:ss]".
    private func parseLRC(_ lrc: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }

            // A single raw line can carry multiple timestamps: "[0:12.00][0:45.00] text"
            var remainder = trimmed
            var timestamps: [TimeInterval] = []
            while remainder.hasPrefix("[") {
                guard let close = remainder.firstIndex(of: "]") else { break }
                let tag = String(remainder[remainder.index(after: remainder.startIndex)..<close])
                if let t = parseTimestamp(tag) { timestamps.append(t) }
                remainder = String(remainder[remainder.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !timestamps.isEmpty else { continue }
            let text = remainder.trimmingCharacters(in: .whitespaces)
            for t in timestamps {
                lines.append(LyricsLine(time: t, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private func parseTimestamp(_ s: String) -> TimeInterval? {
        // "mm:ss.xx" or "mm:ss.x" or "mm:ss"
        let colonParts = s.components(separatedBy: ":")
        guard colonParts.count == 2,
              let minutes = Double(colonParts[0]),
              let seconds = Double(colonParts[1]) else { return nil }
        let t = minutes * 60 + seconds
        return t >= 0 ? t : nil
    }

    // MARK: - Disk cache

    private var cacheDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics_cache", isDirectory: true)
    }

    private func cacheKey(artist: String, track: String, album: String) -> String {
        let raw = "\(artist.lowercased())|\(track.lowercased())|\(album.lowercased())"
        // Use a stable hash for the filename. Swift's `hashValue` is per-session,
        // so fold to a deterministic 64-bit value via DJB2.
        var hash: UInt64 = 5381
        for byte in raw.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }

    private func cacheURL(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadFromCache(key: String) -> LyricsResult? {
        guard let data = try? Data(contentsOf: cacheURL(for: key)),
              let dto  = try? JSONDecoder().decode(CacheDTO.self, from: data) else { return nil }
        return dto.toResult()
    }

    private func saveToCache(_ result: LyricsResult, key: String) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        guard let dto  = CacheDTO(from: result),
              let data = try? JSONEncoder().encode(dto) else { return }
        try? data.write(to: cacheURL(for: key), options: .atomicWrite)
    }

    // MARK: - Cache DTO

    private struct CacheDTO: Codable {
        enum Kind: String, Codable { case synced, plain, instrumental, unavailable }

        struct LineDTO: Codable { let time: Double; let text: String }

        let kind:      Kind
        let lines:     [LineDTO]?
        let plainText: String?

        init?(from result: LyricsResult) {
            switch result {
            case .synced(let ls):
                kind = .synced; lines = ls.map { LineDTO(time: $0.time, text: $0.text) }; plainText = nil
            case .plain(let t):
                kind = .plain; lines = nil; plainText = t
            case .instrumental:
                kind = .instrumental; lines = nil; plainText = nil
            case .unavailable:
                kind = .unavailable; lines = nil; plainText = nil
            }
        }

        func toResult() -> LyricsResult {
            switch kind {
            case .synced:
                let ls = (lines ?? []).map { LyricsLine(time: $0.time, text: $0.text) }
                return ls.isEmpty ? .unavailable : .synced(ls)
            case .plain:
                return (plainText?.isEmpty == false) ? .plain(plainText!) : .unavailable
            case .instrumental: return .instrumental
            case .unavailable:  return .unavailable
            }
        }
    }
}

// MARK: - LRCLIB API response

private struct LRCLIBResponse: Decodable {
    let trackName:     String?
    let artistName:    String?
    let albumName:     String?
    let duration:      Double?
    let instrumental:  Bool?
    let plainLyrics:   String?
    let syncedLyrics:  String?
}
