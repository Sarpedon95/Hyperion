import Foundation

// LyrionAPI is @MainActor: baseURL is written on the main actor by
// updateBaseURL (called from ConnectionManager) and read before every
// network request. The actor isolation ensures reads always see a
// consistent value without manual locking.

@MainActor
final class LyrionAPI {

    static let shared = LyrionAPI()

    private(set) var baseURL: String = ""

    // PERF: single URLSession with tuned connection pool.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // Tags for titles_loop:
    //   A=trackartist C=composer G=genres S=albumartist X=replaygain
    //   c=compilation d=duration e=album_id i=disc l=album t=tracknum
    //   u=url w=work y=year o=type
    private let trackTags = "ACGSXcdeiltuwyo"

    private init() {}

    // MARK: - URL helpers

    func updateBaseURL(_ url: String, persist: Bool = false) {
        let sanitized = sanitize(url)
        if sanitized != baseURL {
            ServerLogStore.shared.info("API base URL changed to \(sanitized.isEmpty ? "not set" : ServerLogStore.redactedURL(sanitized))")
        }
        baseURL = sanitized
        if persist {
            UserDefaults.standard.set(baseURL, forKey: "serverURL")
        }
    }

    private func sanitize(_ url: String) -> String {
        HyperionServerURL.sanitizedBase(url)
    }

    private func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func jsonRPCURL() -> URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/jsonrpc.js")
    }

    /// Returns nil when coverid is nil or empty, preventing broken requests.
    func artworkURL(coverid: String?) -> URL? {
        guard !baseURL.isEmpty, let coverid, !coverid.isEmpty else { return nil }
        return URL(string: "\(baseURL)/music/\(encodedPathComponent(coverid))/cover.jpg")
    }

    /// Ordered LMS playback URLs for AVPlayer.
    func streamURLs(for track: Track) -> [URL] {
        guard !baseURL.isEmpty else { return [] }
        let id = encodedPathComponent(String(track.id))
        var candidates: [String] = []

        if let sourceURL = remoteSafeSourceURL(from: track.url) {
            candidates.append(sourceURL.absoluteString)
        }
        if let ext = playableExtension(from: track.url) {
            candidates.append("\(baseURL)/music/\(id)/download.\(ext)")
        }
        candidates.append("\(baseURL)/music/\(id)/download")
        candidates.append("\(baseURL)/music/\(id)/download?player=0")
        candidates.append("\(baseURL)/music/\(id)/download.mp3")

        var seen = Set<String>()
        return candidates.compactMap { c in
            guard seen.insert(c).inserted else { return nil }
            return URL(string: c)
        }
    }

    func httpHeaders(accept: String? = nil) -> [String: String] {
        var headers = ["User-Agent": "Hyperion iOS"]
        if let accept, !accept.isEmpty {
            headers["Accept"] = accept
        }
        if let auth = HyperionURLAuth.authorizationHeader(from: baseURL) {
            headers["Authorization"] = auth
        }
        return headers
    }

    func streamURL(for track: Track) -> URL? { streamURLs(for: track).first }

    func fallbackStreamURL(for track: Track) -> URL? {
        let urls = streamURLs(for: track)
        return urls.dropFirst().first ?? urls.first
    }

    private func remoteSafeSourceURL(from rawURL: String?) -> URL? {
        guard let rawURL,
              let source = URLComponents(string: rawURL),
              let scheme = source.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        guard let sourceURL = source.url else { return nil }
        guard let baseComponents = URLComponents(string: baseURL),
              let baseHost = baseComponents.host?.lowercased(),
              let sourceHost = source.host?.lowercased() else {
            return sourceURL
        }

        // LMS can return absolute LAN URLs even when the active connection is
        // a remote proxy. Rewrite private/Tailscale LMS hosts onto the active
        // base so remote playback doesn't try to reach an unroutable address.
        let sourceKind = HyperionServerURL.connectionKind(for: rawURL)
        if sourceHost != baseHost, sourceKind != .remote {
            var rewritten = source
            rewritten.scheme = baseComponents.scheme
            rewritten.user = baseComponents.user
            rewritten.password = baseComponents.password
            rewritten.host = baseComponents.host
            rewritten.port = baseComponents.port
            let basePath = baseComponents.percentEncodedPath
            if !basePath.isEmpty, basePath != "/", !rewritten.percentEncodedPath.hasPrefix(basePath + "/") {
                rewritten.percentEncodedPath = basePath + rewritten.percentEncodedPath
            }
            return rewritten.url ?? sourceURL
        }

        return sourceURL
    }

    private func playableExtension(from rawURL: String?) -> String? {
        guard let rawURL, !rawURL.isEmpty else { return nil }

        let path: String
        if let url = URL(string: rawURL), !url.pathExtension.isEmpty {
            path = url.path
        } else {
            path = rawURL
        }

        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return Self.supportedAudioExtensions.contains(ext) ? ext : nil
    }

    /// Audio file extensions that AVPlayer can play directly.
    /// Static so the Set is allocated exactly once.
    private static let supportedAudioExtensions: Set<String> = [
        "aac", "adts", "aif", "aiff", "alac", "caf", "flac",
        "m4a", "m4b", "mp3", "mp4", "wav"
    ]

    /// Broad LMS search. Returns Album matches only; works are intentionally
    /// empty because LMS search does not surface real work_ids we can safely use.
    func searchCatalog(term: String, count: Int = 50) async throws -> (works: [Work], albums: [Album]) {
        try Task.checkCancellation()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }

        // LMS "search" is a server-level (library) command. Using playerID ""
        // targets the server rather than a specific player, which is correct for
        // library searches. playerID "0" also works but is semantically wrong.
        let result = try await request(playerID: "", params: ["search", 0, count, "term:\(trimmed)"])
        let albumHints = Self.parseSearchAlbums(result)
        let hydrated = try await hydrateAlbums(albumHints, desiredCount: count)
        return (works: [], albums: hydrated)
    }

    // MARK: - Core JSON-RPC

    func request(playerID: String = "0", params: [Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let url = jsonRPCURL() else { throw HyperionError.invalidURL }

        let body: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, params]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Hyperion iOS",      forHTTPHeaderField: "User-Agent")
        HyperionURLAuth.addAuthorizationHeader(to: &req, baseURL: baseURL)
        req.timeoutInterval = 10
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let requestSummary = Self.describeRPCParams(params)
        ServerLogStore.shared.debug("RPC start: \(requestSummary) → \(ServerLogStore.redactedURL(url.absoluteString))")

        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let response = try await Self.performRPCRequest(session: session, request: req)
                let duration = Date().timeIntervalSince(started)
                let retryNote = attempt == 1 ? "" : " after \(attempt) attempts"
                ServerLogStore.shared.debug("RPC OK: \(requestSummary) HTTP \(response.statusCode) in \(Self.durationText(duration))\(retryNote)")
                return response.result
            } catch {
                let duration = Date().timeIntervalSince(started)
                if error is CancellationError { throw error }

                lastError = error
                let canRetry = attempt < maxAttempts && Self.isRetryableRPCFailure(error)
                let levelMessage = "RPC \(canRetry ? "retry" : "error"): \(requestSummary) attempt \(attempt)/\(maxAttempts) \(error.localizedDescription) after \(Self.durationText(duration))"

                if canRetry {
                    ServerLogStore.shared.warn(levelMessage)
                    try await Task.sleep(nanoseconds: Self.retryDelayNanoseconds(for: attempt))
                    try Task.checkCancellation()
                    continue
                }

                ServerLogStore.shared.error(levelMessage)
                throw error
            }
        }

        // Unreachable: the loop always returns on success or throws on failure.
        // The compiler requires an expression here because the for-in loop's
        // exhaustiveness is not proven at compile time.
        throw lastError ?? HyperionError.serverError(nil)
    }


    private nonisolated static func isRetryableRPCFailure(_ error: Error) -> Bool {
        if case HyperionError.serverError(let statusCode) = error {
            guard let statusCode else { return true }
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        }

        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotLoadFromNetwork,
             .dnsLookupFailed,
             .badServerResponse:
            return true
        default:
            return false
        }
    }

    private nonisolated static func retryDelayNanoseconds(for attempt: Int) -> UInt64 {
        // Small exponential backoff: 250ms, then 500ms. Keeping this bounded
        // avoids making the UI feel stuck when the user typed a bad server URL.
        let milliseconds = min(250 * (1 << max(0, attempt - 1)), 750)
        return UInt64(milliseconds) * 1_000_000
    }

    private static func describeRPCParams(_ params: [Any]) -> String {
        params.prefix(5).map { String(describing: $0) }.joined(separator: " ")
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }

    private struct RPCResponse {
        let statusCode: Int
        let result: [String: Any]
    }

    /// Runs URLSession and JSON decoding off the MainActor. The public API stays
    /// @MainActor because it owns `baseURL`, while this helper avoids blocking
    /// SwiftUI during large LMS responses such as album/search pages.
    nonisolated private static func performRPCRequest(
        session: URLSession,
        request: URLRequest
    ) async throws -> RPCResponse {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw HyperionError.serverError(nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HyperionError.serverError(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HyperionError.parseError
        }

        if let rpcError = json["error"] as? [String: Any] {
            let code = JSON.int(rpcError["code"])
            let message = rpcError["message"] as? String ?? "Lyrion server returned an error"
            throw HyperionError.rpcError(message, code)
        }

        guard let result = json["result"] as? [String: Any] else {
            throw HyperionError.parseError
        }
        return RPCResponse(statusCode: http.statusCode, result: result)
    }

    // MARK: - Library queries

    func getWorks(
        start: Int = 0,
        count: Int = 500,
        composerID: Int? = nil,
        search: String? = nil
    ) async throws -> [Work] {
        try Task.checkCancellation()
        var params: [Any] = ["works", start, count, "tags:w"]
        if let composerID { params.append("composer_id:\(composerID)") }
        if let search, !search.isEmpty { params.append("search:\(search)") }

        let result = try await request(params: params)
        guard let arr = result["works_loop"] as? [[String: Any]] else { return [] }

        return arr.compactMap { dict in
            guard let workID    = JSON.int(dict["work_id"]),
                  let workTitle = dict["work"] as? String else { return nil }
            return Work(
                work_id:          workID,
                work:             workTitle,
                composer:         Self.normalizeString(dict["composer"] as? String),
                composer_id:      JSON.int(dict["composer_id"]),
                album_id:         JSON.string(dict["album_id"]),
                artwork_track_id: JSON.string(dict["artwork_track_id"])
            )
        }
    }

    func getWorksCount() async throws -> Int? {
        try Task.checkCancellation()
        // count:0 fetches only the metadata (count field) without any data rows.
        let result = try await request(params: ["works", 0, 0, "tags:w"])
        return JSON.int(result["count"]) ?? JSON.int(result["_count"])
    }

    func getAlbumsCount() async throws -> Int? {
        try Task.checkCancellation()
        let result = try await request(params: ["albums", 0, 0, "tags:a"])
        return JSON.int(result["count"]) ?? JSON.int(result["_count"])
    }

    func getTracksForWork(workID: Int) async throws -> [Track] {
        try Task.checkCancellation()
        let result = try await request(params: [
            "titles", 0, 1000, "work_id:\(workID)",
            "tags:\(trackTags)", "sort:tracknum"
        ])
        let raw = Self.parseTracks(result["titles_loop"] as? [[String: Any]] ?? [])
        return raw.sorted { lhs, rhs in
            let ld = lhs.discnum ?? 0, rd = rhs.discnum ?? 0
            if ld != rd { return ld < rd }
            return (lhs.tracknum ?? 0) < (rhs.tracknum ?? 0)
        }
    }

    func getAlbums(
        start: Int = 0,
        count: Int = 100,
        search: String? = nil,
        sort: AlbumSortOrder = .album
    ) async throws -> [Album] {
        try Task.checkCancellation()
        var params: [Any] = ["albums", start, count, "tags:aljySC", "sort:\(sort.lmsValue)"]
        if let search, !search.isEmpty { params.append("search:\(search)") }

        let result = try await request(params: params)
        guard let arr = result["albums_loop"] as? [[String: Any]] else { return [] }
        return Self.parseAlbums(arr)
    }

    /// Hydrates one or more LMS album IDs through the canonical albums query.
    func getAlbumsByIDs(_ ids: [Int], count: Int = 100) async throws -> [Album] {
        try Task.checkCancellation()
        // Deduplicate while preserving order.
        var unique: [Int] = []
        var seen = Set<Int>()
        for id in ids where seen.insert(id).inserted { unique.append(id) }
        guard !unique.isEmpty else { return [] }

        var hydrated: [Album] = []
        hydrated.reserveCapacity(min(unique.count, count))

        var index = 0
        while index < unique.count && hydrated.count < count {
            try Task.checkCancellation()
            let chunk = Array(unique[index..<min(index + 50, unique.count)])
            let joined = chunk.map(String.init).joined(separator: ",")
            let result = try await request(params: [
                "albums", 0, chunk.count, "album_id:\(joined)", "tags:aljySC"
            ])
            let arr = result["albums_loop"] as? [[String: Any]] ?? []
            hydrated.append(contentsOf: Self.parseAlbums(arr))
            index += chunk.count
        }

        return Array(hydrated.prefix(count))
    }

    func getRecentlyPlayed(count: Int = 20) async throws -> [Album] {
        try Task.checkCancellation()
        let sortCandidates = ["lastplayed", "played", "recentlyplayed"]
        var lastError: Error?

        for sort in sortCandidates {
            do {
                let result = try await request(params: [
                    "albums", 0, count, "tags:aljySC", "sort:\(sort)"
                ])
                let arr = result["albums_loop"] as? [[String: Any]] ?? []
                let albums = Self.parseAlbums(arr)
                if !albums.isEmpty { return albums }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
        return []
    }

    func getTracksForAlbum(albumID: Int) async throws -> [Track] {
        try Task.checkCancellation()
        let result = try await request(params: [
            "titles", 0, 1000, "album_id:\(albumID)",
            "tags:\(trackTags)", "sort:tracknum"
        ])
        let raw = Self.parseTracks(result["titles_loop"] as? [[String: Any]] ?? [])
            .map { $0.withAlbumIDIfMissing(albumID) }
        return raw.sorted { lhs, rhs in
            let ld = lhs.discnum ?? 0, rd = rhs.discnum ?? 0
            if ld != rd { return ld < rd }
            return (lhs.tracknum ?? 0) < (rhs.tracknum ?? 0)
        }
    }

    func getComposers(start: Int = 0, count: Int = 500) async throws -> [Composer] {
        try Task.checkCancellation()
        let result = try await request(params: ["artists", start, count, "role_id:COMPOSER"])
        guard let arr = result["artists_loop"] as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let id     = JSON.int(dict["id"]),
                  let artist = dict["artist"] as? String else { return nil }
            return Composer(id: id, artist: artist)
        }
    }

    /// Album-title search with layered fallbacks.
    func searchAlbums(term: String, count: Int = 100) async throws -> [Album] {
        try Task.checkCancellation()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [Album] = []
        var seen = Set<Int>()
        let folded = SearchTextNormalizer.folded(trimmed)
        let tokens = SearchTextNormalizer.tokens(from: trimmed)

        func merge(_ albums: [Album]) {
            for album in albums where seen.insert(album.id).inserted {
                results.append(album)
                if results.count >= count { break }
            }
        }

        func matching(_ albums: [Album]) -> [Album] {
            albums.filter {
                SearchTextNormalizer.matchesFoldedQuery($0.album, foldedQuery: folded, tokens: tokens) ||
                SearchTextNormalizer.matchesFoldedQuery($0.artist ?? "", foldedQuery: folded, tokens: tokens) ||
                SearchTextNormalizer.matchesFoldedQuery($0.composer ?? "", foldedQuery: folded, tokens: tokens)
            }
        }

        // 1. Canonical LMS album-title search.
        merge(matching((try? await getAlbums(start: 0, count: count, search: trimmed)) ?? []))

        // 2. Broad LMS search.
        if results.count < count {
            merge(matching(((try? await searchCatalog(term: trimmed, count: count))?.albums) ?? []))
        }

        // 3. Artist/composer-name album lookup.
        if results.count < count {
            merge(matching((try? await getAlbumsByArtist(term: trimmed, count: count)) ?? []))
        }

        // 4. Bounded local server scan — safety net for mid-title matches.
        if results.isEmpty {
            merge(try await scanAlbumsForMatch(
                foldedQuery: folded,
                tokens: tokens,
                desiredCount: count,
                maxScanned: 5_000
            ))
        }

        return results
    }

    func getAlbumsByArtist(term: String, count: Int = 100) async throws -> [Album] {
        try Task.checkCancellation()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let artistResult = try await request(params: ["artists", 0, 50, "search:\(trimmed)"])
        let artistArr = artistResult["artists_loop"] as? [[String: Any]] ?? []
        let artistIDs = artistArr.compactMap { JSON.int($0["id"]) }
        guard !artistIDs.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: [Album].self) { group in
            for id in artistIDs.prefix(5) {
                group.addTask {
                    let result: [String: Any]
                    do {
                        result = try await self.request(params: ["albums", 0, count, "artist_id:\(id)", "tags:aljySC"])
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return []
                    }
                    let arr = result["albums_loop"] as? [[String: Any]] ?? []
                    return Self.parseAlbums(arr)
                }
            }
            var all: [Album] = []
            var seen = Set<Int>()
            for try await batch in group {
                for album in batch where seen.insert(album.id).inserted {
                    all.append(album)
                }
            }
            return all
        }
    }

    private func hydrateAlbums(_ hints: [Album], desiredCount: Int) async throws -> [Album] {
        guard !hints.isEmpty else { return [] }

        var merged: [Album] = []
        var seen = Set<Int>()

        func merge(_ albums: [Album]) {
            for album in albums where seen.insert(album.id).inserted {
                merged.append(album)
                if merged.count >= desiredCount { break }
            }
        }

        let ids = hints.map(\.id)
        if !ids.isEmpty {
            merge((try? await getAlbumsByIDs(ids, count: desiredCount)) ?? [])
        }
        if merged.count < desiredCount { merge(hints) }
        return Array(merged.prefix(desiredCount))
    }

    private func scanAlbumsForMatch(
        foldedQuery: String,
        tokens: [String],
        desiredCount: Int,
        maxScanned: Int
    ) async throws -> [Album] {
        try Task.checkCancellation()
        guard desiredCount > 0, !foldedQuery.isEmpty else { return [] }

        var found: [Album] = []
        var seen = Set<Int>()
        var start = 0
        let batchSize = 250

        while start < maxScanned && found.count < desiredCount {
            try Task.checkCancellation()
            let requestCount = min(batchSize, maxScanned - start)
            let batch = try await getAlbums(start: start, count: requestCount, sort: .album)
            if batch.isEmpty { break }

            for album in batch where seen.insert(album.id).inserted {
                let matches =
                    SearchTextNormalizer.matchesFoldedQuery(album.album, foldedQuery: foldedQuery, tokens: tokens) ||
                    SearchTextNormalizer.matchesFoldedQuery(album.artist ?? "", foldedQuery: foldedQuery, tokens: tokens) ||
                    SearchTextNormalizer.matchesFoldedQuery(album.composer ?? "", foldedQuery: foldedQuery, tokens: tokens)
                if matches { found.append(album) }
                if found.count >= desiredCount { break }
            }

            if batch.count < requestCount { break }
            start += batch.count
        }

        return found
    }

    func testConnection() async -> Bool {
        do {
            _ = try await request(params: ["version", "?"])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Work grouping

    func groupTracksByWork(_ tracks: [Track]) -> [WorkGroup] {
        guard !tracks.isEmpty else { return [] }

        var groups: [WorkGroup]      = []
        var currentKey: String?      = nil
        var currentTitle: String?    = nil
        var currentComposer: String? = nil
        var currentTracks: [Track]   = []

        func keyFor(_ track: Track) -> (key: String, title: String) {
            if let work = track.work, !work.isEmpty {
                return ("w:\(work)|c:\(track.composer ?? "")", work)
            }
            return ("a:\(track.album ?? "")", track.album ?? "Unknown")
        }

        func flush() {
            guard !currentTracks.isEmpty else { return }
            let first = currentTracks[0]
            groups.append(WorkGroup(
                id:        first.id,
                workTitle: currentTitle ?? first.album ?? "Unknown Work",
                composer:  currentComposer,
                tracks:    currentTracks,
                coverid:   first.coverid
            ))
            currentTracks = []
        }

        for track in tracks {
            let (key, title) = keyFor(track)
            if key != currentKey {
                flush()
                currentKey      = key
                currentTitle    = title
                currentComposer = track.composer
            }
            currentTracks.append(track)
        }
        flush()
        return groups
    }

    // MARK: - Private parsing
    // Static so they can be called without capturing self and clarify they are
    // pure transformations.

    nonisolated private static func parseAlbums(_ array: [[String: Any]]) -> [Album] {
        array.compactMap { dict in
            guard let id = JSON.int(dict["id"] ?? dict["album_id"]),
                  let album = Self.albumTitle(from: dict) else { return nil }
            return Album(
                id:               id,
                album:            album,
                artist:           Self.normalizeString(JSON.string(dict["artist"] ?? dict["albumartist"] ?? dict["contributor"])),
                year:             JSON.int(dict["year"]),
                artwork_track_id: JSON.string(dict["artwork_track_id"] ?? dict["coverid"] ?? dict["coverart"]),
                composer:         Self.normalizeString(JSON.string(dict["composer"])),
                isClassical:      JSON.int(dict["isClassical"] ?? dict["classical"])
            )
        }
    }

    nonisolated private static func parseSearchAlbums(_ result: [String: Any]) -> [Album] {
        var albums: [Album] = []
        var seen = Set<Int>()

        func merge(_ incoming: [Album]) {
            for album in incoming where seen.insert(album.id).inserted {
                albums.append(album)
            }
        }

        for key in ["albums_loop", "album_loop", "albums"] {
            if let rows = result[key] as? [[String: Any]] {
                merge(Self.parseAlbums(rows))
            }
        }

        if let single = Self.parseAlbums([result]).first {
            merge([single])
        }

        return albums
    }

    nonisolated private static func albumTitle(from dict: [String: Any]) -> String? {
        for key in ["album", "albu", "title", "name"] {
            if let value = JSON.string(dict[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated private static func parseTracks(_ array: [[String: Any]]) -> [Track] {
        array.compactMap { dict in
            guard let id = JSON.int(dict["id"]) else { return nil }
            return Track(
                id:          id,
                title:       dict["title"]       as? String ?? "",
                album:       dict["album"]        as? String,
                albumID:     JSON.int(dict["album_id"] ?? dict["albumid"]),
                albumartist: Self.normalizeString(dict["albumartist"] as? String),
                composer:    Self.normalizeString(dict["composer"]    as? String),
                trackartist: Self.normalizeString(dict["trackartist"] as? String),
                work:        Self.normalizeString(dict["work"]        as? String),
                duration:    JSON.double(dict["duration"]),
                tracknum:    JSON.int(dict["tracknum"]),
                discnum:     JSON.int(dict["disc"] ?? dict["discnum"]),
                year:        JSON.int(dict["year"]),
                coverid:     JSON.string(dict["coverid"] ?? dict["artwork_track_id"]),
                url:         dict["url"]          as? String,
                genres:      dict["genres"]       as? String,
                isClassical: JSON.int(dict["isClassical"])
            )
        }
    }

    /// Strips LMS placeholder strings so they are treated as absent.
    nonisolated private static func normalizeString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // PERF: static constant — allocated exactly once at startup.
        if trimmed.isEmpty || placeholderStrings.contains(trimmed.lowercased()) { return nil }
        return trimmed
    }

    /// Set of LMS placeholder strings that should be treated as absent.
    /// Static so allocation happens once across the process lifetime.
    nonisolated private static let placeholderStrings: Set<String> = [
        "not applicable", "unknown", "various artists", "va", "various"
    ]
}

// MARK: - Album sort order

enum AlbumSortOrder: String, CaseIterable, Identifiable {
    case album  = "Album"
    case artist = "Artist"
    case year   = "Year"
    case new    = "Recently Added"

    var id: String { rawValue }

    var lmsValue: String {
        switch self {
        case .album:  return "album"
        case .artist: return "artflow"
        case .year:   return "year"
        case .new:    return "new"
        }
    }
}

// MARK: - JSON coercion helpers
// LMS returns numeric fields inconsistently — sometimes Int, sometimes String,
// occasionally Double. These coerce defensively without throwing.

private enum JSON {
    static func int(_ any: Any?) -> Int? {
        switch any {
        case let i as Int:      return i
        case let d as Double:   return Int(d)
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(t)    { return i }
            if let d = Double(t) { return Int(d) }
            return nil
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double:   return d
        case let i as Int:      return Double(i)
        case let s as String:   return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    static func string(_ any: Any?) -> String? {
        switch any {
        case let s as String:   return s
        case let i as Int:      return String(i)
        case let d as Double:   return String(Int(d))
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}

// MARK: - Error types

enum HyperionError: Error, LocalizedError {
    case invalidURL
    case serverError(Int?)
    case parseError
    case rpcError(String, Int?)
    case noPlayer
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .serverError(let c):
            return c.map { "Server error (HTTP \($0))" } ?? "Server error"
        case .parseError:
            return "Failed to parse server response"
        case .rpcError(let message, let code):
            return code.map { "\(message) (RPC \($0))" } ?? message
        case .noPlayer:
            return "No player found"
        case .notConnected:
            return "Not connected to server"
        }
    }
}
