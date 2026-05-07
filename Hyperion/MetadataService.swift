import Foundation

// MARK: - Public types

struct SimilarArtist: Codable, Identifiable {
    var id: String { name }
    let name: String
    let imageURL: URL?
}

enum MetadataSource: String, Codable {
    case musicBrainz, lastFm, discogs, openOpus

    var displayName: String {
        switch self {
        case .musicBrainz: return "MusicBrainz"
        case .lastFm:      return "Last.fm"
        case .discogs:     return "Discogs"
        case .openOpus:    return "OpenOpus"
        }
    }
}

struct MetadataResult: Codable {
    let artistBio: String?
    let artistImageURL: URL?
    let similarArtists: [SimilarArtist]
    let tags: [String]
    let albumReview: String?
    let albumGenre: String?
    let albumReleaseYear: String?
    let albumLabel: String?
    let source: MetadataSource
}

// MARK: - Service

@MainActor
final class MetadataService {

    static let shared = MetadataService()
    private init() {}

    private var memoryCache: [String: MetadataResult] = [:]

    private let cacheDir: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("metadata_cache", isDirectory: true)
    }()

    // MARK: - Public entry point

    /// Fetch enriched metadata for an artist + optional album. Returns nil gracefully on total failure.
    func fetch(artist: String, album: String? = nil, track: Track? = nil) async -> MetadataResult? {
        let key = cacheKey(artist: artist, album: album ?? "")

        if let hit = memoryCache[key] { return hit }
        if let hit = loadDiskCache(key: key) { memoryCache[key] = hit; return hit }

        let classical = isClassical(track: track)
        let result: MetadataResult?

        if classical {
            result = await fetchClassical(artist: artist, album: album)
        } else {
            result = await fetchNonClassical(artist: artist, album: album)
        }

        if let result {
            memoryCache[key] = result
            saveDiskCache(result, key: key)
        }
        return result
    }

    // MARK: - Classical detection

    private func isClassical(track: Track?) -> Bool {
        guard let track else { return false }
        if track.composer != nil { return true }
        let classicalKeywords = ["classical", "opera", "orchestral", "chamber", "baroque", "romantic", "contemporary classical"]
        if let genre = track.genres?.lowercased() {
            for kw in classicalKeywords where genre.contains(kw) { return true }
        }
        return false
    }

    // MARK: - Classical fetch (OpenOpus portrait + Last.fm bio)

    private func fetchClassical(artist: String, album: String?) async -> MetadataResult? {
        async let ooResult  = fetchOpenOpusPortrait(composer: artist)
        async let lfmResult = LastFmProvider.shared.fetch(artist: artist, album: album)

        let (portrait, lfm) = await (ooResult, lfmResult)

        let imageURL = portrait ?? lfm?.artistImageURL
        let bio      = lfm?.artistBio
        let similar  = lfm?.similarArtists ?? []
        let tags     = lfm?.tags           ?? []

        guard imageURL != nil || bio != nil || !tags.isEmpty else { return nil }

        return MetadataResult(
            artistBio:        bio,
            artistImageURL:   imageURL,
            similarArtists:   similar,
            tags:             tags,
            albumReview:      lfm?.albumReview,
            albumGenre:       lfm?.albumGenre,
            albumReleaseYear: lfm?.albumReleaseYear,
            albumLabel:       lfm?.albumLabel,
            source:           .openOpus
        )
    }

    private func fetchOpenOpusPortrait(composer: String) async -> URL? {
        do {
            let composers = try await MetadataService.withTimeout(seconds: 5) {
                try await OpenOpusService.shared.searchComposers(name: composer)
            }
            if let c = composers.first, let portrait = c.portrait, !portrait.isEmpty {
                return URL(string: portrait)
            }
        } catch {}
        return nil
    }

    // MARK: - Non-classical fetch (MusicBrainz → Last.fm → Discogs)

    private func fetchNonClassical(artist: String, album: String?) async -> MetadataResult? {
        if let result = await MusicBrainzProvider.shared.fetch(artist: artist, album: album) {
            return result
        }
        if let result = await LastFmProvider.shared.fetch(artist: artist, album: album) {
            return result
        }
        if let result = await DiscogsProvider.shared.fetch(artist: artist, album: album) {
            return result
        }
        return nil
    }

    // MARK: - Cache

    private func cacheKey(artist: String, album: String) -> String {
        let raw = "v1|\(artist.lowercased())|\(album.lowercased())"
        var hash: UInt64 = 5381
        for byte in raw.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }

    private func cacheURL(for key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadDiskCache(key: String) -> MetadataResult? {
        guard let data = try? Data(contentsOf: cacheURL(for: key)),
              let result = try? JSONDecoder().decode(MetadataResult.self, from: data) else { return nil }
        return result
    }

    private func saveDiskCache(_ result: MetadataResult, key: String) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: cacheURL(for: key), options: .atomicWrite)
    }

    // MARK: - Timeout helper

    static func withTimeout<T: Sendable>(seconds: Double, _ work: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - MusicBrainz Provider

final class MusicBrainzProvider: @unchecked Sendable {

    static let shared = MusicBrainzProvider()
    private init() {}

    private let base = "https://musicbrainz.org/ws/2"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    // MusicBrainz ToS requires at most 1 request per second.
    // This actor serialises all requests and inserts the necessary gap.
    private actor RateLimiter {
        private var lastRequest: Date = .distantPast
        private let minInterval: TimeInterval = 1.1

        func wait() async {
            let elapsed = Date().timeIntervalSince(lastRequest)
            if elapsed < minInterval {
                let ns = UInt64((minInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
            lastRequest = Date()
        }
    }
    private let rateLimiter = RateLimiter()

    func fetch(artist: String, album: String?) async -> MetadataResult? {
        do {
            return try await MetadataService.withTimeout(seconds: 5) {
                await self.fetchInternal(artist: artist, album: album)
            }
        } catch { return nil }
    }

    private func fetchInternal(artist: String, album: String?) async -> MetadataResult? {
        guard let enc = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/artist/?query=\(enc)&fmt=json") else { return nil }

        guard let data = try? await fetch(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artists = json["artists"] as? [[String: Any]],
              let first = artists.first,
              let mbid = first["id"] as? String else { return nil }

        // Fetch artist details
        let detailURL = URL(string: "\(base)/artist/\(mbid)?inc=tags+ratings&fmt=json")
        var tags: [String] = []
        if let detailURL,
           let detailData = try? await fetch(url: detailURL),
           let detailJSON = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any],
           let tagArr = detailJSON["tags"] as? [[String: Any]] {
            tags = tagArr.prefix(8).compactMap { $0["name"] as? String }
        }

        // Fetch release info if album provided
        var releaseYear: String?
        var label: String?
        let genre: String?  = nil

        if let album {
            let encArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let encAlbum  = album.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let releaseURLStr = "\(base)/release/?query=artist:\(encArtist)+release:\(encAlbum)&fmt=json"
            if let releaseURL = URL(string: releaseURLStr),
               let releaseData = try? await fetch(url: releaseURL),
               let releaseJSON = try? JSONSerialization.jsonObject(with: releaseData) as? [String: Any],
               let releases = releaseJSON["releases"] as? [[String: Any]],
               let rel = releases.first {
                if let dateStr = rel["date"] as? String {
                    releaseYear = String(dateStr.prefix(4))
                }
                if let labelInfo = rel["label-info"] as? [[String: Any]],
                   let labelDict = labelInfo.first,
                   let labelObj = labelDict["label"] as? [String: Any] {
                    label = labelObj["name"] as? String
                }
            }
        }

        if tags.isEmpty && releaseYear == nil { return nil }

        return MetadataResult(
            artistBio:        nil,
            artistImageURL:   nil,
            similarArtists:   [],
            tags:             tags,
            albumReview:      nil,
            albumGenre:       genre,
            albumReleaseYear: releaseYear,
            albumLabel:       label,
            source:           .musicBrainz
        )
    }

    private func fetch(url: URL) async throws -> Data {
        await rateLimiter.wait()
        var req = URLRequest(url: url)
        req.setValue("Hyperion/1.0 (iOS music player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

// MARK: - Last.fm Provider

final class LastFmProvider: @unchecked Sendable {

    static let shared = LastFmProvider()
    private init() {}

    private var apiKey: String { SecretsProvider.lastFmApiKey }
    private let base   = "https://ws.audioscrobbler.com/2.0/"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    func fetch(artist: String, album: String?) async -> MetadataResult? {
        do {
            return try await MetadataService.withTimeout(seconds: 5) {
                await self.fetchInternal(artist: artist, album: album)
            }
        } catch { return nil }
    }

    private func fetchInternal(artist: String, album: String?) async -> MetadataResult? {
        let encArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        async let artistInfo    = fetchArtistInfo(encArtist: encArtist)
        async let similarArtists = fetchSimilarArtists(encArtist: encArtist)
        let encAlbum = album.map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
        async let albumInfo: AlbumData? = encAlbum != nil ? fetchAlbumInfo(encArtist: encArtist, encAlbum: encAlbum ?? "") : nil

        let (info, similar, albumData) = await (artistInfo, similarArtists, albumInfo)

        let bio     = info?.bio
        let image   = info?.imageURL
        let tags    = info?.tags ?? albumData?.tags ?? []
        let genre   = tags.first

        guard bio != nil || image != nil || !similar.isEmpty else { return nil }

        return MetadataResult(
            artistBio:        bio,
            artistImageURL:   image,
            similarArtists:   similar,
            tags:             tags,
            albumReview:      albumData?.review,
            albumGenre:       genre,
            albumReleaseYear: albumData?.releaseYear,
            albumLabel:       nil,
            source:           .lastFm
        )
    }

    // MARK: Artist info

    private struct ArtistInfo {
        let bio: String?
        let imageURL: URL?
        let tags: [String]
    }

    private func fetchArtistInfo(encArtist: String) async -> ArtistInfo? {
        let urlStr = "\(base)?method=artist.getinfo&artist=\(encArtist)&api_key=\(apiKey)&format=json"
        guard let url = URL(string: urlStr),
              let data = try? await fetch(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artistObj = json["artist"] as? [String: Any] else { return nil }

        let bioRaw = (artistObj["bio"] as? [String: Any])?["summary"] as? String
        let bio    = bioRaw.map { stripHTML($0) }?.nilIfEmpty()

        var imageURL: URL?
        if let images = artistObj["image"] as? [[String: Any]] {
            let sorted = images.sorted {
                sizeRank($0["size"] as? String) > sizeRank($1["size"] as? String)
            }
            if let urlStr = sorted.first?["#text"] as? String, !urlStr.isEmpty {
                imageURL = URL(string: urlStr)
            }
        }

        var tags: [String] = []
        if let tagObj = artistObj["tags"] as? [String: Any],
           let tagArr = tagObj["tag"] as? [[String: Any]] {
            tags = tagArr.prefix(6).compactMap { $0["name"] as? String }
        }

        return ArtistInfo(bio: bio, imageURL: imageURL, tags: tags)
    }

    // MARK: Similar artists

    private func fetchSimilarArtists(encArtist: String) async -> [SimilarArtist] {
        let urlStr = "\(base)?method=artist.getsimilar&artist=\(encArtist)&limit=6&api_key=\(apiKey)&format=json"
        guard let url = URL(string: urlStr),
              let data = try? await fetch(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let similar = json["similarartists"] as? [String: Any],
              let arr = similar["artist"] as? [[String: Any]] else { return [] }

        return arr.prefix(6).compactMap { dict -> SimilarArtist? in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            var imageURL: URL?
            if let images = dict["image"] as? [[String: Any]] {
                let sorted = images.sorted { sizeRank($0["size"] as? String) > sizeRank($1["size"] as? String) }
                if let urlStr = sorted.first?["#text"] as? String, !urlStr.isEmpty {
                    imageURL = URL(string: urlStr)
                }
            }
            return SimilarArtist(name: name, imageURL: imageURL)
        }
    }

    // MARK: Album info

    private struct AlbumData {
        let review: String?
        let releaseYear: String?
        let tags: [String]
    }

    private func fetchAlbumInfo(encArtist: String, encAlbum: String) async -> AlbumData? {
        let urlStr = "\(base)?method=album.getinfo&artist=\(encArtist)&album=\(encAlbum)&api_key=\(apiKey)&format=json"
        guard let url = URL(string: urlStr),
              let data = try? await fetch(url: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let albumObj = json["album"] as? [String: Any] else { return nil }

        let reviewRaw = (albumObj["wiki"] as? [String: Any])?["summary"] as? String
        let review    = reviewRaw.map { stripHTML($0) }?.nilIfEmpty()

        var tags: [String] = []
        if let tagObj = albumObj["tags"] as? [String: Any],
           let tagArr = tagObj["tag"] as? [[String: Any]] {
            tags = tagArr.prefix(6).compactMap { $0["name"] as? String }
        }

        return AlbumData(review: review, releaseYear: nil, tags: tags)
    }

    // MARK: Helpers

    private func fetch(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func sizeRank(_ size: String?) -> Int {
        switch size {
        case "mega":  return 4
        case "extralarge": return 3
        case "large": return 2
        case "medium": return 1
        default:      return 0
        }
    }

    private func stripHTML(_ s: String) -> String {
        var result = s
        // Strip <a href="...">...</a> links entirely
        if let rx = try? NSRegularExpression(pattern: "<a[^>]*>.*?</a>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            result = rx.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Strip remaining tags
        if let rx = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) {
            result = rx.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Discogs Provider

final class DiscogsProvider: @unchecked Sendable {

    static let shared = DiscogsProvider()
    private init() {}

    // Read token directly from Keychain to avoid a @MainActor hop from non-isolated context.
    private var token: String { KeychainManager.shared.load(key: "discogs.accessToken") ?? "" }
    private let base  = "https://api.discogs.com"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 5
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    func fetch(artist: String, album: String?) async -> MetadataResult? {
        do {
            return try await MetadataService.withTimeout(seconds: 5) {
                await self.fetchInternal(artist: artist, album: album)
            }
        } catch { return nil }
    }

    private func fetchInternal(artist: String, album: String?) async -> MetadataResult? {
        guard let album else { return nil }
        let tok = token
        guard !tok.isEmpty else { return nil }

        let items: [URLQueryItem] = [
            URLQueryItem(name: "artist",        value: artist),
            URLQueryItem(name: "release_title", value: album),
            URLQueryItem(name: "token",         value: tok)
        ]
        guard var comps = URLComponents(string: "\(base)/database/search") else { return nil }
        comps.queryItems = items
        guard let searchURL = comps.url,
              let data = try? await fetch(url: searchURL, token: tok),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let releaseID = first["id"] as? Int else { return nil }

        // Fetch release detail
        let detailURL = URL(string: "\(base)/releases/\(releaseID)?token=\(tok)")
        guard let detailURL,
              let detailData = try? await fetch(url: detailURL, token: tok),
              let detailJSON = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any] else { return nil }

        let year   = (detailJSON["year"] as? Int).map { String($0) }
        let genres = detailJSON["genres"] as? [String] ?? []
        let styles = detailJSON["styles"] as? [String] ?? []
        let labels = (detailJSON["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let notes  = (detailJSON["notes"] as? String)?.nilIfEmpty()

        let tags = Array((genres + styles).prefix(8))

        guard !tags.isEmpty || year != nil || notes != nil else { return nil }

        return MetadataResult(
            artistBio:        nil,
            artistImageURL:   nil,
            similarArtists:   [],
            tags:             tags,
            albumReview:      notes,
            albumGenre:       genres.first,
            albumReleaseYear: year,
            albumLabel:       labels.first,
            source:           .discogs
        )
    }

    private func fetch(url: URL, token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Hyperion/1.0 (iOS music player)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

// MARK: - String helpers

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
