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

/// A scored candidate returned by the manual search API.
struct LyricsCandidate: Identifiable {
    let id:         Int
    let trackName:  String
    let artistName: String
    let albumName:  String?
    let duration:   TimeInterval?
    let hasSynced:  Bool
    let score:      Double
    let result:     LyricsResult
}

// MARK: - Provider protocols

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

/// Optional capability for providers that support manual candidate search.
/// Conform to this alongside `LyricsProvider` to enable the in-app search UI.
protocol LyricsSearchableProvider: LyricsProvider {
    func searchCandidates(artist: String, track: String) async -> [LyricsCandidate]
}

// MARK: - Service (coordinator + cache)

@MainActor
final class LyricsService {

    static let shared = LyricsService()
    private init() {}

    /// Swap at startup if a licensed provider with a valid key is configured.
    var provider: any LyricsProvider = LRCLIBProvider()

    // In-memory cache keyed by track ID — survives the session, avoids disk I/O on repeat visits.
    private var memoryCache: [Int: LyricsResult] = [:]

    // Mirrors the on-disk pin store so reads never block the main thread.
    private var pinStoreCache: PinStore?

    // MARK: - Public

    /// Synchronous memory-cache probe — returns instantly if lyrics were already fetched.
    func cachedResult(trackID: Int) -> LyricsResult? {
        memoryCache[trackID]
    }

    /// Kick off a background fetch so lyrics are ready before the user opens the view.
    /// Safe to call on every track change; skips work if the result is already in memory.
    func prefetch(for track: Track) {
        let tid = track.id
        guard memoryCache[tid] == nil else { return }
        let artist = track.composer ?? track.albumartist ?? track.trackartist ?? ""
        let artistResolved = artist.isEmpty ? track.title : artist
        let title  = (track.work?.isEmpty == false ? track.work : nil) ?? track.title
        let album  = track.album ?? ""
        Task {
            _ = await self.lyrics(
                artistName: artistResolved,
                trackName:  title,
                albumName:  album.isEmpty ? nil : album,
                duration:   (track.duration ?? 0) > 0 ? track.duration : nil,
                trackID:    tid
            )
        }
    }

    /// Returns cached lyrics instantly, or fetches via the active provider (5-second timeout).
    /// Negative results ("unavailable") are only cached after all provider
    /// fallback attempts have been exhausted.
    /// If `trackID` is provided and a pin exists for it, the pin takes priority.
    func lyrics(
        artistName: String,
        trackName:  String,
        albumName:  String?,
        duration:   TimeInterval?,
        trackID:    Int? = nil
    ) async -> LyricsResult {
        if let tid = trackID, let hit = memoryCache[tid] {
            lyricsLog("Memory hit — trackID \(tid)")
            return hit
        }

        if let tid = trackID, let pinned = loadPin(trackID: tid) {
            lyricsLog("Pin hit — trackID \(tid)")
            memoryCache[tid] = pinned
            return pinned
        }

        let key = cacheKey(artist: artistName, track: trackName, album: albumName ?? "")

        if let cached = await loadFromCache(key: key) {
            lyricsLog("Cache hit — '\(trackName)' by '\(artistName)'")
            if let tid = trackID { memoryCache[tid] = cached }
            return cached
        }

        lyricsLog("Fetching '\(trackName)' by '\(artistName)' via \(type(of: provider))")
        let result: LyricsResult
        do {
            result = try await withThrowingTaskGroup(of: LyricsResult.self) { group in
                group.addTask { [provider] in
                    await provider.fetch(
                        artistName: artistName,
                        trackName:  trackName,
                        albumName:  albumName,
                        duration:   duration
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw CancellationError()
                }
                let r = try await group.next() ?? .unavailable
                group.cancelAll()
                return r
            }
        } catch {
            lyricsLog("Fetch timed out or failed — '\(trackName)'")
            result = .unavailable
        }

        saveToCache(result, key: key)
        if let tid = trackID { memoryCache[tid] = result }
        return result
    }

    /// Search for ranked lyrics candidates — used by the manual search UI.
    /// Returns an empty array if the active provider does not support candidate search.
    func searchCandidates(artist: String, track: String) async -> [LyricsCandidate] {
        guard let searchable = provider as? LyricsSearchableProvider else { return [] }
        return await searchable.searchCandidates(artist: artist, track: track)
    }

    /// Pin a manually-chosen candidate to the cache under the original track's key.
    /// Called after the user selects a result in ManualLyricsSearchView.
    func pinResult(_ candidate: LyricsCandidate, artist: String, track: String, album: String) {
        let key = cacheKey(artist: artist, track: track, album: album)
        saveToCache(candidate.result, key: key)
        lyricsLog("Pinned '\(candidate.trackName)' by '\(candidate.artistName)' for '\(track)'")
    }

    /// Pin with an explicit trackID so the pin survives artist/title changes.
    func pinResult(candidate: LyricsCandidate, trackID: Int, artist: String, track: String, album: String) {
        pinResult(candidate, artist: artist, track: track, album: album)
        savePin(candidate.result, trackID: trackID)
        lyricsLog("Pinned trackID \(trackID) → '\(candidate.trackName)'")
    }

    // MARK: - Pin file (tracks pinned by track ID)

    private var pinsURL: URL { AppFiles.url(for: "lyrics_pins.json") }

    private typealias PinStore = [String: CacheDTO]

    private func loadPins() -> PinStore {
        if let cached = pinStoreCache { return cached }
        let store: PinStore
        if let data = try? Data(contentsOf: pinsURL),
           let decoded = try? JSONDecoder().decode(PinStore.self, from: data) {
            store = decoded
        } else {
            store = [:]
        }
        pinStoreCache = store
        return store
    }

    private func loadPin(trackID: Int) -> LyricsResult? {
        let store = loadPins()
        return store[String(trackID)]?.toResult()
    }

    private func savePin(_ result: LyricsResult, trackID: Int) {
        guard let dto = CacheDTO(from: result) else { return }
        var store = loadPins()
        store[String(trackID)] = dto
        pinStoreCache = store
        // Flush to disk off the main thread.
        let url = pinsURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(store) else { return }
            try? data.write(to: url, options: .atomicWrite)
        }
    }

    /// Wipe the entire on-disk lyrics cache (e.g. after a lookup-logic upgrade).
    func clearCache() {
        let dir = cacheDir
        Task.detached(priority: .background) {
            try? FileManager.default.removeItem(at: dir)
        }
        lyricsLog("Cache cleared")
    }

    // MARK: - Disk cache

    // FIXED: use Caches directory (OS can evict on low storage; no iCloud backup).
    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics_cache", isDirectory: true)
    }

    private static let cacheTTL: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    // FIXED: v3 key — artist + track only (no album) deduplicates same track on multiple albums.
    // v2 → v3 bust automatically: old hashes never collide with new ones.
    private func cacheKey(artist: String, track: String, album: String) -> String {
        let raw = "v3|\(artist.lowercased())|\(track.lowercased())"
        var hash: UInt64 = 5381
        for byte in raw.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }

    private func cacheURL(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadFromCache(key: String) async -> LyricsResult? {
        let url = cacheURL(for: key)
        let ttl = Self.cacheTTL
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let dto  = try? JSONDecoder().decode(CacheDTO.self, from: data) else { return nil }
            // Reject stale entries older than 30 days.
            if let fetchedAt = dto.fetchedAt, Date().timeIntervalSince(fetchedAt) > ttl {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return dto.toResult()
        }.value
    }

    private func saveToCache(_ result: LyricsResult, key: String) {
        let url = cacheURL(for: key)
        let dir = cacheDir
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let dto  = CacheDTO(from: result),
                  let data = try? JSONEncoder().encode(dto) else { return }
            try? data.write(to: url, options: .atomicWrite)
        }
    }

    // MARK: - Cache DTO

    struct CacheDTO: Codable {
        enum Kind: String, Codable { case synced, plain, instrumental, unavailable }
        struct LineDTO: Codable { let time: Double; let text: String }

        let kind:      Kind
        let lines:     [LineDTO]?
        let plainText: String?
        // FIXED: timestamp for 30-day TTL; nil means pre-v3 entry (treated as fresh for compat)
        let fetchedAt: Date?

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
            fetchedAt = Date()
        }

        func toResult() -> LyricsResult {
            switch kind {
            case .synced:
                let ls = (lines ?? []).map { LyricsLine(time: $0.time, text: $0.text) }
                return ls.isEmpty ? .unavailable : .synced(ls)
            case .plain:
                if let text = plainText, !text.isEmpty { return .plain(text) }
                return .unavailable
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
/// No authentication required. Uses a multi-step lookup ladder with local
/// candidate ranking so remaster/edition suffixes don't prevent matches.
final class LRCLIBProvider: LyricsSearchableProvider, @unchecked Sendable {

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    private let base = "https://lrclib.net/api"

    // MARK: - LyricsProvider

    /// Deterministic lookup ladder:
    ///   1. Exact    — original title, album, duration
    ///   2. Norm     — normalized title (strips remaster/edition/live suffixes)
    ///   3. No album — normalized title, no album
    ///   4. No dur   — normalized title, no album, no duration
    ///   5. Search   — four parallel queries, local ranking, threshold ≥ 0.40
    ///
    /// `.unavailable` is returned only after all five steps fail.
    func fetch(
        artistName: String,
        trackName:  String,
        albumName:  String?,
        duration:   TimeInterval?
    ) async -> LyricsResult {
        let norm     = LRCLIBProvider.normalizeTitle(trackName)
        let hasDur   = (duration ?? 0) > 0
        let hasAlbum = !(albumName?.isEmpty ?? true)
        let didNorm  = norm != trackName

        lyricsLog("──────────────────────────────────────────")
        lyricsLog("Lookup '\(trackName)'\(didNorm ? " → normalized '\(norm)'" : "")")
        lyricsLog("  artist='\(artistName)' album='\(albumName ?? "–")' duration=\(duration.map { String(format: "%.0f", $0) } ?? "–")s")

        // Step 1: exact original title
        lyricsLog("Step 1: exact (original title)")
        if let r = await getExact(artist: artistName, track: trackName,
                                   album: albumName, duration: duration) {
            lyricsLog("✓ Step 1 → \(resultDescription(r))")
            return r
        }

        // Step 2: normalized title (skip if title is already clean)
        if didNorm {
            lyricsLog("Step 2: normalized title '\(norm)'")
            if let r = await getExact(artist: artistName, track: norm,
                                       album: albumName, duration: duration) {
                lyricsLog("✓ Step 2 → \(resultDescription(r))")
                return r
            }
        }

        // Step 3: no album
        if hasAlbum {
            lyricsLog("Step 3: normalized, no album")
            if let r = await getExact(artist: artistName, track: norm,
                                       album: nil, duration: duration) {
                lyricsLog("✓ Step 3 → \(resultDescription(r))")
                return r
            }
        }

        // Step 4: no duration
        if hasDur {
            lyricsLog("Step 4: normalized, no album, no duration")
            if let r = await getExact(artist: artistName, track: norm,
                                       album: nil, duration: nil) {
                lyricsLog("✓ Step 4 → \(resultDescription(r))")
                return r
            }
        }

        // Step 5: multi-query search with local ranking
        lyricsLog("Step 5: multi-query search")
        return await multiSearch(artist: artistName, track: norm, duration: duration)
    }

    // MARK: - LyricsSearchableProvider

    func searchCandidates(artist: String, track: String) async -> [LyricsCandidate] {
        async let r1 = fetchSearchPage(params: [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name",  value: track)
        ])
        async let r2 = fetchSearchPage(params: [URLQueryItem(name: "q", value: "\(artist) \(track)")])
        async let r3 = fetchSearchPage(params: [URLQueryItem(name: "q", value: track)])

        let (c1, c2, c3) = await (r1, r2, r3)
        let all = deduplicated(c1 + c2 + c3)

        return all.compactMap { c -> LyricsCandidate? in
            guard let id = c.id else { return nil }
            let score = rankCandidate(c, targetArtist: artist, targetTrack: track, duration: nil)
            return LyricsCandidate(
                id:         id,
                trackName:  c.trackName  ?? "",
                artistName: c.artistName ?? "",
                albumName:  c.albumName,
                duration:   c.duration,
                hasSynced:  c.syncedLyrics?.isEmpty == false,
                score:      score,
                result:     resultFrom(c)
            )
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Exact lookup (/api/get)

    /// Returns `nil` on 404 (so the ladder continues) and on network errors.
    /// Returns a concrete result only on HTTP 200 with usable lyrics content.
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
        lyricsLog("  GET \(url.absoluteString)")

        do {
            let (data, response) = try await session.data(for: makeRequest(url))
            guard let http = response as? HTTPURLResponse else { return nil }
            lyricsLog("  → HTTP \(http.statusCode)")
            // 404 = definitively not in LRCLIB with these params — return nil so
            // the lookup ladder continues to the next step (previously returned
            // .unavailable which short-circuited the entire ladder).
            if http.statusCode == 404 { return nil }
            guard http.statusCode == 200 else { return nil }
            let payload = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
            let result  = resultFrom(payload)
            // Empty payload (no lyrics content) → treat as miss so we try further steps
            if case .unavailable = result {
                lyricsLog("  → empty payload, continuing ladder")
                return nil
            }
            lyricsLog("  → \(resultDescription(result))")
            return result
        } catch {
            lyricsLog("  getExact error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Multi-query search

    private func multiSearch(artist: String, track: String, duration: TimeInterval?) async -> LyricsResult {
        // Run four queries in parallel; merge, deduplicate, then rank locally.
        // Queries: structured artist+track, free-text "artist track",
        //          free-text "track artist" (reversed), free-text title-only.
        async let r1 = fetchSearchPage(params: [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name",  value: track)
        ])
        async let r2 = fetchSearchPage(params: [URLQueryItem(name: "q", value: "\(artist) \(track)")])
        async let r3 = fetchSearchPage(params: [URLQueryItem(name: "q", value: "\(track) \(artist)")])
        async let r4 = fetchSearchPage(params: [URLQueryItem(name: "q", value: track)])

        let (c1, c2, c3, c4) = await (r1, r2, r3, r4)
        let all = deduplicated(c1 + c2 + c3 + c4)
        lyricsLog("  \(all.count) unique candidate(s) [q1:\(c1.count) q2:\(c2.count) q3:\(c3.count) q4:\(c4.count)]")

        let scored: [(LRCLIBResponse, Double)] = all.compactMap { c in
            let s = rankCandidate(c, targetArtist: artist, targetTrack: track, duration: duration)
            lyricsLog("  Candidate '\(c.trackName ?? "?")' by '\(c.artistName ?? "?")'  score=\(String(format: "%.2f", s))  synced=\(c.syncedLyrics?.isEmpty == false)")
            return s >= 0.40 ? (c, s) : nil
        }.sorted { $0.1 > $1.1 }

        guard let (best, bestScore) = scored.first else {
            lyricsLog("✗ No candidate met threshold 0.40 → unavailable")
            return .unavailable
        }
        let r = resultFrom(best)
        lyricsLog("✓ Accepted '\(best.trackName ?? "")' by '\(best.artistName ?? "")'  score=\(String(format: "%.2f", bestScore)) → \(resultDescription(r))")
        return r
    }

    private func fetchSearchPage(params: [URLQueryItem]) async -> [LRCLIBResponse] {
        guard let url = makeURL("\(base)/search", params) else { return [] }
        lyricsLog("  GET \(url.absoluteString)")
        do {
            let (data, response) = try await session.data(for: makeRequest(url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return (try? JSONDecoder().decode([LRCLIBResponse].self, from: data)) ?? []
        } catch {
            lyricsLog("  fetchSearchPage error: \(error.localizedDescription)")
            return []
        }
    }

    private func deduplicated(_ items: [LRCLIBResponse]) -> [LRCLIBResponse] {
        var seen = Set<Int>()
        return items.filter { c in
            guard let id = c.id else { return true }
            return seen.insert(id).inserted
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

        let titleScore: Double = tTrack.similarity(cTrack)

        // Partial credit for substring containment before falling back to full similarity.
        let artistScore: Double
        if tArtist == cArtist {
            artistScore = 1.0
        } else if tArtist.contains(cArtist) || cArtist.contains(tArtist) {
            artistScore = 0.8
        } else {
            artistScore = tArtist.similarity(cArtist)
        }

        // Duration proximity — graded penalty: -0.25 per 30 s off, floored at 0.
        // When duration is unknown on either side, we don't penalise.
        var durationScore = 1.0
        if let target = duration, target > 0, let cDur = c.duration, cDur > 0 {
            let diff = abs(target - cDur)
            durationScore = Swift.max(0, 1.0 - (diff / 30.0) * 0.25)
        }

        let syncedBonus = (c.syncedLyrics?.isEmpty == false) ? 0.05 : 0.0

        // Weighted: title 45%, artist 35%, duration 15%, synced quality bonus 5%
        return titleScore * 0.45 + artistScore * 0.35 + durationScore * 0.15 + syncedBonus
    }

    // MARK: - Title normalization

    /// Strips common suffixes that prevent LRCLIB from matching, supporting
    /// both parentheses `(…)` and square brackets `[…]` variants:
    ///
    ///   "Money (2023 Remaster)"          → "Money"
    ///   "Money (2011 Remastered Version)" → "Money"
    ///   "Money [2023 Remaster]"           → "Money"
    ///   "Money - 2023 Remaster"           → "Money"
    ///   "Money (Remastered)"              → "Money"
    ///   "The Wall (Deluxe Edition)"       → "The Wall"
    ///   "Comfortably Numb (Live)"         → "Comfortably Numb"
    static func normalizeTitle(_ title: String) -> String {
        var s = title

        // Bracket patterns: strips matching content inside (…) or […]
        let bracketPatterns: [String] = [
            // Year + Remaster(ed) + optional Version: (2023 Remaster), (2011 Remastered Version)
            "\\(\\d{4}[- ]Remaster(?:ed)?(?:\\s+Version)?\\)",
            "\\[\\d{4}[- ]Remaster(?:ed)?(?:\\s+Version)?\\]",
            // Remaster(ed) + optional year + optional Version: (Remastered), (Remastered 2023)
            "\\(Remaster(?:ed)?(?:[- ]\\d{4})?(?:\\s+Version)?\\)",
            "\\[Remaster(?:ed)?(?:[- ]\\d{4})?(?:\\s+Version)?\\]",
            // Edition info
            "\\((?:Deluxe|Special|Super Deluxe|Expanded|Anniversary|Ultimate|Collector's?)(?:[- ]Edition)?\\)",
            "\\[(?:Deluxe|Special|Super Deluxe|Expanded|Anniversary|Ultimate|Collector's?)(?:[- ]Edition)?\\]",
            // Edit / version / mix variants
            "\\((?:Radio|Single|Album|Extended|Acoustic|Alternate|Alternative)[- ](?:Edit|Version|Mix)\\)",
            "\\[(?:Radio|Single|Album|Extended|Acoustic|Alternate|Alternative)[- ](?:Edit|Version|Mix)\\]",
            "\\((?:Radio|Single|Album|Extended)\\)",
            // Live
            "\\(Live(?:[- ](?:at|@|from)[^)]*)?\\)",
            "\\[Live(?:[- ](?:at|@|from)[^\\]]*)?\\]",
            "\\(Live[^)]*\\)",
            // Featured artists
            "\\(feat(?:\\.?uring)?[.:]?\\s+[^)]+\\)",
            "\\(ft\\.?\\s+[^)]+\\)",
            // Bonus / hidden tracks
            "\\[(?:Bonus|Hidden)[^\\]]*\\]",
            "\\(Bonus[^)]*\\)",
            // Mono / stereo mix
            "\\((?:Mono|Stereo)(?:[- ](?:Mix|Version|Remaster(?:ed)?))?\\)",
            "\\[(?:Mono|Stereo)(?:[- ](?:Mix|Version|Remaster(?:ed)?))?\\]",
        ]

        // Dash patterns: strips matching suffixes at the end of the title
        let dashPatterns: [String] = [
            "\\s+-\\s+\\d{4}[- ]Remaster(?:ed)?(?:\\s+Version)?$",
            "\\s+-\\s+Remaster(?:ed)?(?:[- ]\\d{4})?(?:\\s+Version)?$",
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

    private func resultDescription(_ r: LyricsResult) -> String {
        switch r {
        case .synced(let ls): return "synced(\(ls.count) lines)"
        case .plain(let t):   return "plain(\(t.count) chars)"
        case .instrumental:   return "instrumental"
        case .unavailable:    return "unavailable"
        }
    }
}

// MARK: - LRCLIB wire types

private struct LRCLIBResponse: Decodable {
    let id:           Int?
    let trackName:    String?
    let artistName:   String?
    let albumName:    String?
    let duration:     Double?
    let instrumental: Bool?
    let plainLyrics:  String?
    let syncedLyrics: String?
}
