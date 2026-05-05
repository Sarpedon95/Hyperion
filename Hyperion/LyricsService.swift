import Foundation

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
    case synced([LyricsLine])   // time-stamped lines
    case plain(String)          // full text, no timestamps
    case instrumental           // confirmed instrumental by provider
    case unavailable            // no lyrics after all attempts
}

// MARK: - Provider protocol

/// Abstraction over a lyrics data source.
///
/// To add a licensed provider (Musixmatch, Genius, …) later:
///   1. Create a type that conforms to `LyricsProvider`.
///   2. At app startup, inject an API key from your config/keychain and set
///      `LyricsService.shared.provider = YourProvider(apiKey: key)`.
///   3. Do NOT hardcode keys, scrape, or call private/unofficial endpoints.
protocol LyricsProvider: Sendable {
    func fetch(
        artistName: String,
        trackName:  String,
        albumName:  String?,
        duration:   TimeInterval?
    ) async -> LyricsResult
}

// MARK: - Service (coordinator + cache)

@MainActor
final class LyricsService {

    static let shared = LyricsService()
    private init() {}

    /// Swap at startup if a licensed provider with a valid key is configured.
    var provider: any LyricsProvider = LRCLIBProvider()

    // MARK: - Public

    /// Returns cached lyrics instantly, or fetches via the active provider.
    /// Negative results ("unavailable") are only cached after all provider
    /// fallback attempts have been exhausted.
    func lyrics(
        artistName: String,
        trackName:  String,
        albumName:  String?,
        duration:   TimeInterval?
    ) async -> LyricsResult {
        let key = cacheKey(artist: artistName, track: trackName, album: albumName ?? "")

        if let cached = loadFromCache(key: key) {
            lyricsLog("Cache hit — '\(trackName)' by '\(artistName)'")
            return cached
        }

        lyricsLog("Fetching '\(trackName)' by '\(artistName)' via \(type(of: provider))")
        let result = await provider.fetch(
            artistName: artistName,
            trackName:  trackName,
            albumName:  albumName,
            duration:   duration
        )
        saveToCache(result, key: key)
        return result
    }

    // MARK: - Disk cache

    private var cacheDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics_cache", isDirectory: true)
    }

    // DJB2 — stable across sessions (unlike Swift's hashValue).
    private func cacheKey(artist: String, track: String, album: String) -> String {
        let raw = "\(artist.lowercased())|\(track.lowercased())|\(album.lowercased())"
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

    struct CacheDTO: Codable {
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

// MARK: - Debug logging

func lyricsLog(_ message: String) {
#if DEBUG
    print("[Lyrics] \(message)")
#endif
}

// MARK: - LRCLIB provider

/// Free, public, community-maintained lyrics database (https://lrclib.net).
/// No authentication required. Uses multi-step lookup with local ranking so
/// remaster/edition suffixes don't prevent matches.
final class LRCLIBProvider: LyricsProvider, @unchecked Sendable {

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    private let base = "https://lrclib.net/api"

    // MARK: - LyricsProvider

    /// Multi-step strategy:
    ///   1. Exact lookup — original title, album, duration
    ///   2. Normalized title — strips remaster/edition/live suffixes
    ///   3. No album — album mismatch in LRCLIB is common for classical
    ///   4. No duration — tolerance fallback
    ///   5. Search endpoint — ranked locally, threshold ≥ 0.40
    ///
    /// `.unavailable` is returned only after all five steps fail.
    func fetch(
        artistName: String,
        trackName:  String,
        albumName:  String?,
        duration:   TimeInterval?
    ) async -> LyricsResult {
        let norm       = LRCLIBProvider.normalizeTitle(trackName)
        let hasDur     = (duration ?? 0) > 0
        let hasAlbum   = !(albumName?.isEmpty ?? true)
        let didNorm    = norm != trackName

        lyricsLog("Lookup '\(trackName)'\(didNorm ? " → '\(norm)'" : "") artist='\(artistName)'")

        // Step 1: exact original
        if let r = await getExact(artist: artistName, track: trackName,
                                   album: albumName, duration: duration) {
            lyricsLog("  ✓ Step 1 (exact)")
            return r
        }

        // Step 2: normalized title
        if didNorm {
            if let r = await getExact(artist: artistName, track: norm,
                                       album: albumName, duration: duration) {
                lyricsLog("  ✓ Step 2 (normalized title)")
                return r
            }
        }

        // Step 3: no album
        if hasAlbum {
            if let r = await getExact(artist: artistName, track: norm,
                                       album: nil, duration: duration) {
                lyricsLog("  ✓ Step 3 (no album)")
                return r
            }
        }

        // Step 4: no duration
        if hasDur {
            if let r = await getExact(artist: artistName, track: norm,
                                       album: nil, duration: nil) {
                lyricsLog("  ✓ Step 4 (no duration)")
                return r
            }
        }

        // Step 5: search + local ranking
        lyricsLog("  → Step 5 (search fallback)")
        return await search(artist: artistName, track: norm, duration: duration)
    }

    // MARK: - Exact lookup (/api/get)

    /// Returns `nil` on network error (so the caller can try the next step).
    /// Returns `.unavailable` on 404 (definitive miss for these params).
    private func getExact(
        artist: String, track: String, album: String?, duration: TimeInterval?
    ) async -> LyricsResult? {
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
        guard let url = makeURL("\(base)/get", items) else { return nil }

        do {
            let (data, response) = try await session.data(for: makeRequest(url))
            guard let http = response as? HTTPURLResponse else { return nil }
            // 404 = definitively not found for these params — don't retry same step
            if http.statusCode == 404 { return .unavailable }
            guard http.statusCode == 200 else { return nil }
            let payload = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            let result  = resultFrom(payload)
            // Treat an empty response (no lyrics content) as a miss so we try
            // further steps instead of caching an empty result.
            if case .unavailable = result { return nil }
            return result
        } catch {
            lyricsLog("  getExact network error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Search + ranking (/api/search)

    private func search(artist: String, track: String, duration: TimeInterval?) async -> LyricsResult {
        guard let url = makeURL("\(base)/search", [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name",  value: track)
        ]) else { return .unavailable }

        do {
            let (data, response) = try await session.data(for: makeRequest(url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .unavailable
            }
            let candidates = try JSONDecoder().decode([LRCLIBResponse].self, from: data)
            lyricsLog("  Search returned \(candidates.count) candidate(s)")

            let scored: [(LRCLIBResponse, Double)] = candidates.compactMap { c in
                let s = rankCandidate(c, targetArtist: artist, targetTrack: track, duration: duration)
                let cName = c.trackName ?? "?"
                lyricsLog("    '\(cName)' score=\(String(format: "%.2f", s))")
                return s >= 0.40 ? (c, s) : nil
            }.sorted { $0.1 > $1.1 }

            guard let (best, bestScore) = scored.first else {
                lyricsLog("  No candidate met threshold 0.40")
                return .unavailable
            }
            lyricsLog("  Best: '\(best.trackName ?? "")' score=\(String(format: "%.2f", bestScore))")
            return resultFrom(best)
        } catch {
            lyricsLog("  Search network error: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Candidate scoring

    private func rankCandidate(
        _ c: LRCLIBResponse,
        targetArtist: String,
        targetTrack:  String,
        duration:     TimeInterval?
    ) -> Double {
        let cTrack  = LRCLIBProvider.normalizeTitle(c.trackName  ?? "").lowercased()
        let cArtist = (c.artistName ?? "").lowercased()
        let tTrack  = targetTrack.lowercased()
        let tArtist = targetArtist.lowercased()

        // Title similarity
        let titleScore  = tTrack.similarity(cTrack)

        // Artist similarity — partial credit for last-name or first-word match
        let artistScore: Double
        if tArtist == cArtist {
            artistScore = 1.0
        } else if tArtist.contains(cArtist) || cArtist.contains(tArtist) {
            artistScore = 0.8
        } else {
            artistScore = tArtist.similarity(cArtist)
        }

        // Duration proximity — graded penalty: -0.25 per 30 s off, floored at 0
        var durationScore = 1.0
        if let target = duration, target > 0, let cDur = c.duration, cDur > 0 {
            let diff = abs(target - cDur)
            durationScore = Swift.max(0, 1.0 - (diff / 30.0) * 0.25)
        }

        // Small bonus for having synced lyrics (prefer quality)
        let syncedBonus = (c.syncedLyrics?.isEmpty == false) ? 0.05 : 0.0

        // Weighted: title 45 %, artist 35 %, duration 15 %, synced bonus 5 %
        return titleScore * 0.45 + artistScore * 0.35 + durationScore * 0.15 + syncedBonus
    }

    // MARK: - Title normalization

    /// Strips common suffixes that prevent LRCLIB from matching:
    ///   "Money (2023 Remaster)"        → "Money"
    ///   "Wish You Were Here - Remastered 2011" → "Wish You Were Here"
    ///   "The Wall (Deluxe Edition)"    → "The Wall"
    ///   "Comfortably Numb (Live)"      → "Comfortably Numb"
    ///   "Something (feat. George Harrison)" → "Something"
    static func normalizeTitle(_ title: String) -> String {
        var s = title

        // Patterns stripped from inside parentheses / brackets
        let bracketPatterns: [String] = [
            // Remaster with year: (2023 Remaster), (Remaster 2023), (Remastered 2023)
            "\\(\\d{4}[- ]Remaster(?:ed)?\\)",
            "\\(Remaster(?:ed)?[- ]\\d{4}\\)",
            "\\(Remaster(?:ed)?\\)",
            // Edition info
            "\\((?:Deluxe|Special|Super Deluxe|Expanded|Anniversary|Ultimate|Collector's?)(?:[- ]Edition)?\\)",
            // Edit / version / mix variants
            "\\((?:Radio|Single|Album|Extended|Acoustic|Alternate|Alternative)[- ](?:Edit|Version|Mix)\\)",
            "\\((?:Radio|Single|Album|Extended)\\)",
            // Live (optional venue)
            "\\(Live(?:[- ](?:at|@|from)[^)]*)?\\)",
            "\\(Live[^)]*\\)",
            // Featured artists
            "\\(feat(?:\\.?uring)?[.:]?\\s+[^)]+\\)",
            "\\(ft\\.?\\s+[^)]+\\)",
            // Bonus / hidden tracks
            "\\[(?:Bonus|Hidden)[^\\]]*\\]",
            "\\(Bonus[^)]*\\)",
            // Mono / stereo mix
            "\\((?:Mono|Stereo)(?:[- ](?:Mix|Version|Remaster(?:ed)?))?\\)",
        ]

        // Patterns stripped as dash-separated suffixes at the end
        let dashPatterns: [String] = [
            "\\s+-\\s+\\d{4}[- ]Remaster(?:ed)?$",
            "\\s+-\\s+Remaster(?:ed)?(?:[- ]\\d{4})?$",
            "\\s+-\\s+Live(?:\\s+(?:at|@|from)\\s+.+)?$",
            "\\s+-\\s+(?:Radio|Single|Album|Extended)[- ](?:Edit|Version|Mix)$",
            "\\s+-\\s+(?:Mono|Stereo)(?:[- ]Mix)?$",
        ]

        for pattern in bracketPatterns + dashPatterns {
            if let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let r = NSRange(s.startIndex..., in: s)
                s = rx.stringByReplacingMatches(in: s, range: r, withTemplate: "")
            }
        }

        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - LRC parser

    private func parseLRC(_ lrc: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }

            // A line may carry multiple timestamps: "[0:12.00][0:45.00] text"
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
            for t in timestamps { lines.append(LyricsLine(time: t, text: text)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.components(separatedBy: ":")
        guard parts.count == 2,
              let mm = Double(parts[0]),
              let ss = Double(parts[1]),
              mm >= 0, ss >= 0 else { return nil }
        return mm * 60 + ss
    }

    // MARK: - Helpers

    private func makeURL(_ base: String, _ items: [URLQueryItem]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = items
        return c?.url
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Hyperion/1.0 (iOS classical music player)", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func resultFrom(_ payload: LRCLIBResponse) -> LyricsResult {
        if payload.instrumental == true { return .instrumental }
        if let synced = payload.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = payload.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return .unavailable
    }
}

// MARK: - LRCLIB wire types

private struct LRCLIBResponse: Decodable {
    let trackName:    String?
    let artistName:   String?
    let albumName:    String?
    let duration:     Double?
    let instrumental: Bool?
    let plainLyrics:  String?
    let syncedLyrics: String?
}
