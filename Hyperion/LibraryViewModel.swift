import Foundation
import Combine
import UIKit

@MainActor
final class LibraryViewModel: ObservableObject {

    static let shared = LibraryViewModel()

    @Published var composers: [Composer] = [] { didSet { rebuildClassicalContributorIndex() } }
    @Published var artists: [Artist] = []
    @Published var songs: [Track] = []
    @Published var albums: [Album] = [] { didSet { rebuildClassicalContributorIndex() } }
    @Published var recentAlbums: [Album] = []
    @Published var recentlyPlayed: [Album] = []
    @Published var genres: [Genre] = []

    // MARK: - Home ⇄ Classical split outputs
    //
    // Pre-filtered slices so each tab consumes ONLY its own data. Populated by
    // the same load paths that fill `recentlyPlayed` / `recentAlbums`; views
    // never re-derive the split. `home*` = non-classical, `classical*` = classical.
    @Published var homeRecentlyPlayed:      [Album] = []
    @Published var classicalRecentlyPlayed: [Album] = []
    @Published var homeRecentAlbums:        [Album] = []
    @Published var classicalRecentAlbums:   [Album] = []

    /// Genres rail, partitioned by the canonical genre rule.
    var homeGenres:      [Genre] { genres.filter { !$0.isClassicalContent } }
    var classicalGenres: [Genre] { genres.filter {  $0.isClassicalContent } }

    /// Folded names of contributors treated as classical (composers + artists
    /// credited on classical albums). Lets the Home Artists rail/list drop
    /// classical performers without a per-artist genre lookup. Rebuilt whenever
    /// `composers` or `albums` change.
    private(set) var classicalContributorNames: Set<String> = []
    @Published var isLoadingComposers: Bool = false
    @Published var isLoadingWorks: Bool = false
    @Published var isLoadingAlbums: Bool = false
    @Published var isLoadingArtists: Bool = false
    @Published var isLoadingSongs: Bool = false
    @Published var isLoadingGenres: Bool = false
    @Published var error: String? = nil
    @Published var totalWorks:  Int? = nil
    @Published var totalAlbums: Int? = nil
    @Published var totalSongs:  Int? = nil
    @Published var totalArtists: Int? = nil
    /// True once every page of the songs cursor has been fetched. Used by the
    /// Songs tab to stop scheduling `loadNextSongsPage()` once the library is
    /// fully populated.
    @Published var songsExhausted: Bool = false

    private var composerCache: [Composer]? = nil
    private var artistCache: [Artist]? = nil
    private var genreCache: [Genre]? = nil
    private var artistsLoadTask: Task<[Artist], Error>?
    private var genresLoadTask: Task<[Genre], Error>?
    private var songsLoadTask: Task<[Track], Error>?
    /// Cursor for paginated song loading via `loadNextSongsPage()`. Advances by
    /// `pageSize` each successful page; reset to 0 in `clearCache()` / `refresh()`.
    private var nextSongsStart: Int = 0
    /// Single-flight guard for `loadNextSongsPage()` — prevents overlapping
    /// page requests when the user scrolls quickly past the trigger row.
    private var songsPageTask: Task<Void, Never>?

    // MARK: - Artist detail cache

    struct ArtistDetailResult {
        let albums: [Album]
        let songs: [Track]
    }
    /// LRU-style cache capped at 10 artist detail results.
    private var artistDetailCache: [(artistID: Int, result: ArtistDetailResult)] = []
    /// In-flight coalescing: a second navigation to the same artist joins this task.
    private var artistDetailTasks: [Int: Task<ArtistDetailResult, Error>] = [:]

    private enum WorksCacheKey: Hashable {
        case all
        case composer(Int)
    }

    private var worksCache: [WorksCacheKey: [Work]] = [:]
    private var tracksForWork:  [Int: [Track]] = [:]
    private var tracksForAlbum: [Int: [Track]] = [:]
    private var worksLoadTasks:      [WorksCacheKey: Task<[Work],  Error>] = [:]
    private var tracksForWorkTasks:  [Int: Task<[Track], Error>] = [:]
    private var tracksForAlbumTasks: [Int: Task<[Track], Error>] = [:]
    private var hasLoadedAllAlbums: Bool = false
    private var currentAlbumSortOrder: AlbumSortOrder = .album
    private var recentAlbumsTask: Task<[Album], Error>?
    private var recentlyPlayedTask: Task<[Album], Error>?
    private var totalsTask: Task<(Int?, Int?, Int?, Int?), Never>?
    private var recentAlbumsTaskID: UUID?
    private var recentlyPlayedTaskID: UUID?

    private let pageSize = 500

    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.worksCache     = [:]
                self?.tracksForWork  = [:]
                self?.tracksForAlbum = [:]
                self?.worksLoadTasks.values.forEach { $0.cancel() }
                self?.tracksForWorkTasks.values.forEach { $0.cancel() }
                self?.tracksForAlbumTasks.values.forEach { $0.cancel() }
                self?.recentAlbumsTask?.cancel()
                self?.recentlyPlayedTask?.cancel()
                self?.totalsTask?.cancel()
                self?.worksLoadTasks.removeAll()
                self?.tracksForWorkTasks.removeAll()
                self?.tracksForAlbumTasks.removeAll()
                self?.recentAlbumsTask = nil
                self?.recentlyPlayedTask = nil
                self?.totalsTask = nil
                self?.recentAlbumsTaskID = nil
                self?.recentlyPlayedTaskID = nil
                // Keep composerCache — it's small and expensive to refetch.
            }
        }
    }

    // MARK: - Stat tile counts

    /// Fetches and caches total works + albums counts for HomeView stat tiles.
    /// Short-circuits if both are already populated (zero network cost on revisit).
    func loadTotals() async {
        guard totalWorks == nil || totalAlbums == nil || totalSongs == nil || totalArtists == nil else { return }

        if let existing = totalsTask {
            let (w, a, s, ar) = await existing.value
            guard !Task.isCancelled else { return }
            if let w  { totalWorks   = w  }
            if let a  { totalAlbums  = a  }
            if let s  { totalSongs   = s  }
            if let ar { totalArtists = ar }
            return
        }

        let task = Task<(Int?, Int?, Int?, Int?), Never> {
            async let worksCount:   Int? = try? LyrionAPI.shared.getWorksCount()
            async let albumsCount:  Int? = try? LyrionAPI.shared.getAlbumsCount()
            async let songsCount:   Int? = try? LyrionAPI.shared.getSongsCount()
            async let artistsCount: Int? = try? LyrionAPI.shared.getArtistsCount()
            return await (worksCount, albumsCount, songsCount, artistsCount)
        }
        totalsTask = task
        defer { totalsTask = nil }

        let (w, a, s, ar) = await task.value
        guard !Task.isCancelled else { return }
        if let w  { totalWorks   = w  }
        if let a  { totalAlbums  = a  }
        if let s  { totalSongs   = s  }
        if let ar { totalArtists = ar }
    }

    // MARK: - Composers

    /// In-flight task for composer loading — deduplicates concurrent callers.
    private var composersLoadTask: Task<[Composer], Error>?

    func loadComposers() async {
        if let cached = composerCache {
            composers = cached
            return
        }

        // BUGFIX: deduplicate concurrent callers with a shared task. Both
        // ContentView and HomeView call loadComposers on appear; the old
        // isLoadingComposers guard returned early WITHOUT populating composers,
        // so the second caller got no data. Awaiting the shared task ensures
        // every caller receives the result.
        if let existing = composersLoadTask {
            do { composers = try await existing.value } catch { }
            return
        }

        isLoadingComposers = true
        let pageSize = self.pageSize
        let task = Task<[Composer], Error> {
            var all: [Composer] = []
            var start = 0
            while true {
                try Task.checkCancellation()
                let batch = try await LyrionAPI.shared.getComposers(start: start, count: pageSize)
                all.append(contentsOf: batch)
                if batch.count < pageSize { break }
                start += pageSize
            }
            all.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
            return all
        }
        composersLoadTask = task
        defer {
            composersLoadTask = nil
            isLoadingComposers = false
        }

        do {
            let all = try await task.value
            composerCache = all
            composers     = all
        } catch is CancellationError {
            // Task was cancelled; leave existing state intact.
        } catch {
            let userMessage: String
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    userMessage = "Server is responding slowly. Please check your connection."
                case .notConnectedToInternet, .networkConnectionLost:
                    userMessage = "No internet connection. Check WiFi or cellular."
                case .cannotFindHost, .cannotConnectToHost:
                    userMessage = "Cannot reach the server. Check the server address."
                default:
                    userMessage = "Connection problem: \(error.localizedDescription)"
                }
            } else {
                userMessage = error.localizedDescription
            }
            self.error = userMessage
        }
    }


    // MARK: - Genres

    func loadGenres() async {
        if let cached = genreCache {
            genres = cached
            return
        }
        if let existing = genresLoadTask {
            do { genres = try await existing.value } catch { }
            return
        }
        isLoadingGenres = true
        let task = Task<[Genre], Error> {
            let all = try await LyrionAPI.shared.getGenres()
            return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        genresLoadTask = task
        defer { genresLoadTask = nil; isLoadingGenres = false }
        do {
            let all = try await task.value
            genreCache = all
            genres = all
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Artists

    func loadArtists() async {
        if let cached = artistCache {
            artists = cached
            return
        }
        if let existing = artistsLoadTask {
            do { artists = try await existing.value } catch { }
            return
        }
        isLoadingArtists = true
        let pageSize = self.pageSize
        let task = Task<[Artist], Error> {
            var all: [Artist] = []
            var start = 0
            while true {
                try Task.checkCancellation()
                let batch = try await LyrionAPI.shared.getAllArtists(start: start, count: pageSize)
                all.append(contentsOf: batch)
                if batch.count < pageSize { break }
                start += pageSize
            }
            all.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return all
        }
        artistsLoadTask = task
        defer { artistsLoadTask = nil; isLoadingArtists = false }
        do {
            let all = try await task.value
            artistCache = all
            artists = all
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Artist detail (cached, coalesced)

    /// Loads albums and songs for an artist, with in-flight coalescing and a
    /// 10-entry LRU cache so repeated navigations are instant.
    func loadArtistDetail(artistID: Int) async throws -> ArtistDetailResult {
        // Cache hit — bump to front for LRU eviction.
        if let idx = artistDetailCache.firstIndex(where: { $0.artistID == artistID }) {
            let entry = artistDetailCache.remove(at: idx)
            artistDetailCache.append(entry)
            return entry.result
        }
        // In-flight coalescing — join the existing task rather than duplicating requests.
        if let existing = artistDetailTasks[artistID] {
            return try await existing.value
        }

        let task = Task<ArtistDetailResult, Error> { @MainActor in
            async let albumsResult = LyrionAPI.shared.getAlbumsForArtist(artistID: artistID)
            async let tracksResult = LyrionAPI.shared.getTracksForArtist(artistID: artistID)
            var loadedAlbums = (try? await albumsResult) ?? []
            loadedAlbums.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
            let loadedTracks = (try? await tracksResult) ?? []
            return ArtistDetailResult(albums: loadedAlbums, songs: loadedTracks)
        }
        artistDetailTasks[artistID] = task
        defer { artistDetailTasks[artistID] = nil }

        let result = try await task.value
        // Evict oldest entry if cache is full.
        if artistDetailCache.count >= 10 { artistDetailCache.removeFirst() }
        artistDetailCache.append((artistID: artistID, result: result))
        return result
    }

    // MARK: - Songs

    /// Loads the full library track-by-track. Prefer `loadNextSongsPage()` for
    /// scroll-driven UIs — this method blocks until every page has been fetched
    /// and is appropriate only when a caller genuinely needs the entire library
    /// in memory (e.g., FocusMode, MixGenerator client-side filtering).
    func loadSongs() async {
        if songsExhausted {
            ServerLogStore.shared.debug("[LoadSongs] Already fully loaded (\(songs.count) songs) — skipping")
            return
        }
        if let existing = songsLoadTask {
            ServerLogStore.shared.debug("[LoadSongs] In-flight full load already running — joining it")
            _ = try? await existing.value
            return
        }
        ServerLogStore.shared.debug("[LoadSongs] Starting full library song load")
        isLoadingSongs = true
        let pageSize = self.pageSize
        // Resume from wherever the cursor pagination left off so a callback that
        // really needs the full library doesn't refetch pages already in memory.
        let resumeStart = nextSongsStart
        let task = Task<[Track], Error> {
            var all: [Track] = []
            var start = resumeStart
            while true {
                try Task.checkCancellation()
                let batch = try await LyrionAPI.shared.getAllSongs(start: start, count: pageSize)
                all.append(contentsOf: batch)
                if start == 0 && self.songs.isEmpty {
                    self.songs = all
                }
                if batch.count < pageSize { break }
                start += pageSize
            }
            return all
        }
        songsLoadTask = task
        defer { songsLoadTask = nil; isLoadingSongs = false }
        do {
            let remaining = try await task.value
            if resumeStart == 0 {
                songs = remaining
            } else {
                songs.append(contentsOf: remaining)
            }
            nextSongsStart = songs.count
            songsExhausted = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads exactly one page of songs and appends to `songs`. Idempotent and
    /// cancellation-safe — concurrent callers (e.g. multiple list rows triggering
    /// near-end on fast scrolls) coalesce onto the same task.
    ///
    /// AUDIT-FIX: replaces the eager full-library fetch for the Songs tab. The
    /// caller drives further pages by invoking this again as the user nears the
    /// end of the list; `songsExhausted` flips once a short page indicates the
    /// cursor has reached the tail.
    func loadNextSongsPage() async {
        if songsExhausted { return }
        if let inFlight = songsPageTask {
            await inFlight.value
            return
        }
        let pageStart = nextSongsStart
        let pageCount = pageSize
        // If the full-library task is already running, defer to it rather than
        // racing for the same cursor — its completion will mark songsExhausted.
        if songsLoadTask != nil {
            _ = try? await songsLoadTask?.value
            return
        }
        isLoadingSongs = true
        let task = Task<Void, Never> { @MainActor in
            defer { isLoadingSongs = false }
            do {
                let batch = try await LyrionAPI.shared.getAllSongs(start: pageStart, count: pageCount)
                // Guard against a concurrent clearCache() that reset the cursor
                // between the await and our append — drop the stale page rather
                // than corrupting the freshly cleared list.
                guard nextSongsStart == pageStart else { return }
                songs.append(contentsOf: batch)
                nextSongsStart = pageStart + batch.count
                if batch.count < pageCount {
                    songsExhausted = true
                }
            } catch is CancellationError {
                // Cancellation: leave cursor alone so a later caller can retry.
            } catch {
                self.error = error.localizedDescription
            }
        }
        songsPageTask = task
        defer { songsPageTask = nil }
        await task.value
    }

    // ADDED: server-side text filter — avoids loading the full library just for a subset.
    // Returns up to `limit` tracks whose title/artist match `query` via LMS search.
    func loadSongs(matching query: String, limit: Int = 100) async throws -> [Track] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try await LyrionAPI.shared.searchTracks(term: query, count: limit)
    }

    // MARK: - Track resolution (server-backed)

    /// Resolves track IDs to `Track` objects, preferring the in-memory library
    /// and fetching anything not yet paginated in from the server via
    /// `getSong(id:)`. Order of `ids` is preserved; IDs that cannot be resolved
    /// (deleted tracks, server offline) are dropped.
    ///
    /// This is the canonical way for features (AI Mixes, Focus Mode, Siri,
    /// downloads) to turn stored track IDs into playable tracks. Filtering the
    /// in-memory `songs` array directly is unsafe because `songs` is lazily
    /// paginated and is empty on a cold launch.
    func resolveTracks(ids: [Int]) async -> [Track] {
        guard !ids.isEmpty else { return [] }

        var byID = [Int: Track](minimumCapacity: songs.count)
        for track in songs { byID[track.id] = track }

        let missing = ids.filter { byID[$0] == nil }
        if !missing.isEmpty {
            let fetched = await withTaskGroup(of: Track?.self) { group -> [Track] in
                for id in missing {
                    group.addTask { try? await LyrionAPI.shared.getSong(id: id) }
                }
                var out: [Track] = []
                out.reserveCapacity(missing.count)
                for await track in group { if let track { out.append(track) } }
                return out
            }
            for track in fetched { byID[track.id] = track }
        }

        return ids.compactMap { byID[$0] }
    }

    // MARK: - Works

    func loadWorks(composerID: Int? = nil) async throws -> [Work] {
        let key: WorksCacheKey = composerID.map { .composer($0) } ?? .all
        if let cached = worksCache[key] { return cached }
        if let existing = worksLoadTasks[key] { return try await existing.value }

        let pageSize = self.pageSize
        let task = Task<[Work], Error> {
            var all: [Work] = []
            var start = 0

            while true {
                try Task.checkCancellation()
                let batch = try await LyrionAPI.shared.getWorks(
                    start: start,
                    count: pageSize,
                    composerID: composerID
                )
                all.append(contentsOf: batch)
                if batch.count < pageSize { break }
                start += pageSize
            }

            all.sort { $0.work.localizedCaseInsensitiveCompare($1.work) == .orderedAscending }
            return all
        }

        // BUGFIX: store the task BEFORE the first await so any concurrent caller
        // that passes the worksLoadTasks[key] guard above sees this task and
        // awaits it rather than spawning a duplicate network request.
        worksLoadTasks[key] = task
        // Always show the spinner for any new work-load task, regardless of
        // whether other tasks are already running.
        isLoadingWorks = true

        defer {
            worksLoadTasks[key] = nil
            // Only hide the spinner once ALL concurrent work-load tasks have finished.
            if worksLoadTasks.isEmpty { isLoadingWorks = false }
        }

        do {
            let all = try await task.value
            worksCache[key] = all
            return all
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    // MARK: - Albums

    private var albumsLoadGeneration = UUID()

    func loadAlbums(reset: Bool = false, sort: AlbumSortOrder = .album) async {
        let sortChanged = sort != currentAlbumSortOrder
        let shouldReset = reset || sortChanged

        if shouldReset {
            // Bump generation so any in-flight load discards its results
            // rather than appending to the freshly-cleared array.
            albumsLoadGeneration   = UUID()
            albums                 = []
            hasLoadedAllAlbums     = false
            currentAlbumSortOrder  = sort
        } else if isLoadingAlbums || hasLoadedAllAlbums {
            return
        }

        let generation    = albumsLoadGeneration
        let requestedSort = currentAlbumSortOrder
        let start = shouldReset ? 0 : albums.count

        isLoadingAlbums = true
        defer {
            if generation == albumsLoadGeneration {
                isLoadingAlbums = false
            }
        }

        do {
            try Task.checkCancellation()
            let batch = try await LyrionAPI.shared.getAlbums(
                start: start,
                count: pageSize,
                sort: requestedSort
            )
            guard !Task.isCancelled, generation == albumsLoadGeneration else { return }

            albums.append(contentsOf: batch)
            if batch.count < pageSize {
                hasLoadedAllAlbums = true
            }
        } catch is CancellationError {
            // Ignore.
        } catch {
            self.error = userFriendlyErrorMessage(for: error)
        }
    }

    /// Recently-added albums are split by the album-level classifier (genre tag
    /// when present, else server `isClassical` flag / composer credit).
    private func applyRecentAlbums(_ albums: [Album]) {
        recentAlbums          = albums
        homeRecentAlbums      = albums.filter { !$0.isClassicalContent }
        classicalRecentAlbums = albums.filter {  $0.isClassicalContent }
    }

    func loadRecentAlbums(force: Bool = false) async {
        if !force && !recentAlbums.isEmpty { return }
        if force {
            recentAlbumsTask?.cancel()
            recentAlbumsTask = nil
            recentAlbumsTaskID = nil
        } else if let existing = recentAlbumsTask {
            do {
                let albums = try await existing.value
                guard !Task.isCancelled else { return }
                applyRecentAlbums(albums)
            } catch { }
            return
        }

        let taskID = UUID()
        let task = Task<[Album], Error> {
            try await LyrionAPI.shared.getAlbums(start: 0, count: 20, sort: .new)
        }
        recentAlbumsTask   = task
        recentAlbumsTaskID = taskID
        defer {
            if recentAlbumsTaskID == taskID {
                recentAlbumsTask   = nil
                recentAlbumsTaskID = nil
            }
        }

        do {
            let albums = try await task.value
            guard !Task.isCancelled, recentAlbumsTaskID == taskID else { return }
            applyRecentAlbums(albums)
        } catch is CancellationError {
            // Ignore.
        } catch {
            guard recentAlbumsTaskID == taskID else { return }
            self.error = userFriendlyErrorMessage(for: error)
        }
    }

    /// Rebuilds the recently-played outputs. The local history store is the
    /// genre-accurate source (it captured each track's genre at play time);
    /// the server list is partitioned with the album-level classifier.
    private func applyRecentlyPlayed(server: [Album], limit: Int = 20) {
        let store = PlaybackHistoryStore.shared
        let localAll       = store.recentlyPlayedAlbums(limit: limit)
        let localClassical = store.recentlyPlayedAlbums(classical: true,  limit: limit)
        let localNon       = store.recentlyPlayedAlbums(classical: false, limit: limit)

        let serverClassical = server.filter {  $0.isClassicalContent }
        let serverNon       = server.filter { !$0.isClassicalContent }

        recentlyPlayed          = mergeRecentlyPlayed(local: localAll,       server: server,          limit: limit)
        classicalRecentlyPlayed = mergeRecentlyPlayed(local: localClassical, server: serverClassical, limit: limit)
        homeRecentlyPlayed      = mergeRecentlyPlayed(local: localNon,       server: serverNon,       limit: limit)
    }

    func loadRecentlyPlayed(force: Bool = false) async {
        if !force && !recentlyPlayed.isEmpty { return }

        // Genre-accurate local history first; server enrichment merges in below.
        applyRecentlyPlayed(server: [])

        if force {
            recentlyPlayedTask?.cancel()
            recentlyPlayedTask = nil
            recentlyPlayedTaskID = nil
        } else if let existing = recentlyPlayedTask {
            do {
                let server = try await existing.value
                guard !Task.isCancelled else { return }
                applyRecentlyPlayed(server: server)
            } catch { }
            return
        }

        let taskID = UUID()
        let task = Task<[Album], Error> {
            try await LyrionAPI.shared.getRecentlyPlayed(count: 20)
        }
        recentlyPlayedTask   = task
        recentlyPlayedTaskID = taskID
        defer {
            if recentlyPlayedTaskID == taskID {
                recentlyPlayedTask   = nil
                recentlyPlayedTaskID = nil
            }
        }

        do {
            let server = try await task.value
            guard !Task.isCancelled, recentlyPlayedTaskID == taskID else { return }
            applyRecentlyPlayed(server: server)
        } catch is CancellationError {
            // Ignore.
        } catch {
            // Non-fatal: not all LMS versions expose play history reliably.
        }
    }

    func recordPlayback(_ track: Track) {
        let store = PlaybackHistoryStore.shared
        store.recordPlayback(of: track)
        // Re-merge each slice with its own genre-accurate local history so a new
        // play only ever lands in the correct tab.
        recentlyPlayed = mergeRecentlyPlayed(
            local:  store.recentlyPlayedAlbums(limit: 20),
            server: recentlyPlayed, limit: 20)
        homeRecentlyPlayed = mergeRecentlyPlayed(
            local:  store.recentlyPlayedAlbums(classical: false, limit: 20),
            server: homeRecentlyPlayed, limit: 20)
        classicalRecentlyPlayed = mergeRecentlyPlayed(
            local:  store.recentlyPlayedAlbums(classical: true, limit: 20),
            server: classicalRecentlyPlayed, limit: 20)
    }

    private func mergeRecentlyPlayed(local: [Album], server: [Album], limit: Int) -> [Album] {
        var seen = Set<Int>()
        var merged: [Album] = []
        merged.reserveCapacity(limit)

        for album in local + server {
            guard seen.insert(album.id).inserted else { continue }
            merged.append(album)
            if merged.count == limit { break }
        }
        return merged
    }

    // MARK: - Artist classification (Home ⇄ Classical)

    /// True when an artist should be treated as classical and kept off Home.
    /// Backed by `classicalContributorNames`; unknown artists default to
    /// non-classical (shown on Home) until composer/album data has loaded.
    func isClassicalArtist(_ name: String) -> Bool {
        let folded = SearchTextNormalizer.folded(name)
        guard !folded.isEmpty else { return false }
        return classicalContributorNames.contains(folded)
    }

    /// Non-classical artists for the Home rail/list.
    var homeArtists: [Artist] {
        artists.filter { !isClassicalArtist($0.name) }
    }

    private func rebuildClassicalContributorIndex() {
        var names = Set<String>()
        for composer in composers {
            let f = SearchTextNormalizer.folded(composer.artist)
            if !f.isEmpty { names.insert(f) }
        }
        for album in albums where album.isClassicalContent {
            if let artist = album.artist {
                let f = SearchTextNormalizer.folded(artist)
                if !f.isEmpty { names.insert(f) }
            }
        }
        classicalContributorNames = names
    }

    // MARK: - Tracks

    func getTracksForWork(_ workID: Int) async throws -> [Track] {
        if let cached = tracksForWork[workID] { return cached }
        if let existing = tracksForWorkTasks[workID] { return try await existing.value }

        let task = Task<[Track], Error> {
            try await LyrionAPI.shared.getTracksForWork(workID: workID)
        }
        tracksForWorkTasks[workID] = task
        defer { tracksForWorkTasks[workID] = nil }

        do {
            let tracks = try await task.value
            tracksForWork[workID] = tracks
            return tracks
        } catch is CancellationError {
            // Don't cache on cancellation — next caller should retry.
            throw CancellationError()
        } catch {
            // Don't cache on network error — task slot cleared by defer so
            // the next caller triggers a fresh request rather than hanging.
            throw error
        }
    }

    func getTracksForAlbum(_ albumID: Int) async throws -> [Track] {
        if let cached = tracksForAlbum[albumID] { return cached }
        if let existing = tracksForAlbumTasks[albumID] { return try await existing.value }

        let task = Task<[Track], Error> {
            try await LyrionAPI.shared.getTracksForAlbum(albumID: albumID)
        }
        tracksForAlbumTasks[albumID] = task
        defer { tracksForAlbumTasks[albumID] = nil }

        do {
            let tracks = try await task.value
            tracksForAlbum[albumID] = tracks
            return tracks
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    func getWorkGroupsForAlbum(_ albumID: Int) async throws -> [WorkGroup] {
        let tracks = try await getTracksForAlbum(albumID)
        return LyrionAPI.shared.groupTracksByWork(tracks)
    }

    // MARK: - Search

    typealias SearchResults = (composers: [Composer], works: [Work], albums: [Album], artists: [Artist], tracks: [Track], genres: [Genre], playlists: [LocalPlaylist])

    /// In-memory only search — returns results immediately without any network calls.
    func searchLocal(query: String) -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], [], [], [], [], [], []) }

        let needle = SearchTextNormalizer.Needle(trimmed)

        var foundComposers: [Composer] = []
        var foundWorks:     [Work]     = []
        var foundAlbums:    [Album]    = []
        var foundArtists:   [Artist]   = []
        var foundTracks:    [Track]    = []
        var seenComposerIDs = Set<Int>()
        var seenWorkIDs     = Set<Int>()
        var seenWorkKeys    = Set<String>()
        var seenAlbumIDs    = Set<Int>()
        var seenArtistIDs   = Set<Int>()
        var seenTrackIDs    = Set<Int>()

        composers.filter { needle.matches($0.artist) }.forEach { c in
            guard seenComposerIDs.insert(c.id).inserted else { return }
            foundComposers.append(c)
        }
        artists.filter { needle.matches($0.name) }.forEach { a in
            guard seenArtistIDs.insert(a.id).inserted else { return }
            foundArtists.append(a)
        }
        songs.filter {
            needle.matches($0.title) ||
            needle.matches($0.trackartist ?? $0.albumartist ?? "") ||
            needle.matches($0.album ?? "")
        }.forEach { t in
            guard seenTrackIDs.insert(t.id).inserted else { return }
            foundTracks.append(t)
        }
        albums.filter {
            needle.matches($0.album) ||
            needle.matches($0.artist   ?? "") ||
            needle.matches($0.composer ?? "")
        }.forEach { a in
            guard seenAlbumIDs.insert(a.id).inserted else { return }
            foundAlbums.append(a)
        }
        for cached in worksCache.values {
            cached.filter {
                needle.matches($0.work) ||
                needle.matches($0.composer ?? "")
            }.forEach { w in
                if w.work_id > 0 {
                    guard seenWorkIDs.insert(w.work_id).inserted else { return }
                } else {
                    let key = "\(w.work)|\(w.composer ?? "")"
                    guard seenWorkKeys.insert(key).inserted else { return }
                }
                foundWorks.append(w)
            }
        }
        let matchedGenres = genres.filter { needle.matches($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let matchedPlaylists = PlaylistStore.shared.playlists.filter { needle.matches($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return (
            Array(foundComposers.prefix(30)),
            Array(foundWorks.prefix(50)),
            Array(foundAlbums.prefix(60)),
            Array(foundArtists.prefix(20)),
            Array(foundTracks.prefix(30)),
            Array(matchedGenres.prefix(15)),
            Array(matchedPlaylists.prefix(15))
        )
    }

    func search(query: String) async -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], [], [], [], [], [], []) }

        let needle = SearchTextNormalizer.Needle(trimmed)

        var foundComposers: [Composer] = []
        var foundWorks:     [Work]     = []
        var foundAlbums:    [Album]    = []
        var foundArtists:   [Artist]   = []
        var foundTracks:    [Track]    = []
        var seenComposerIDs = Set<Int>()
        var seenWorkIDs     = Set<Int>()
        var seenWorkKeys    = Set<String>()
        var seenAlbumIDs    = Set<Int>()
        var seenArtistIDs   = Set<Int>()
        var seenTrackIDs    = Set<Int>()

        func mergeComposer(_ c: Composer) {
            guard seenComposerIDs.insert(c.id).inserted else { return }
            foundComposers.append(c)
        }
        func mergeWork(_ w: Work) {
            if w.work_id > 0 {
                guard seenWorkIDs.insert(w.work_id).inserted else { return }
            } else {
                let key = "\(w.work)|\(w.composer ?? "")"
                guard seenWorkKeys.insert(key).inserted else { return }
            }
            foundWorks.append(w)
        }
        func mergeAlbum(_ a: Album) {
            guard seenAlbumIDs.insert(a.id).inserted else { return }
            foundAlbums.append(a)
        }

        // 1. Local composer search (only searches data already in memory — never blocks on load)
        composers.filter { needle.matches($0.artist) }.forEach { mergeComposer($0) }

        // 1a. Local artist search
        artists.filter { needle.matches($0.name) }.forEach { a in
            if seenArtistIDs.insert(a.id).inserted { foundArtists.append(a) }
        }

        // 1b. Local track search (only searches data already in memory — never blocks on load)
        songs.filter {
            needle.matches($0.title) ||
            needle.matches($0.trackartist ?? $0.albumartist ?? "") ||
            needle.matches($0.album ?? "")
        }.forEach { t in
            if seenTrackIDs.insert(t.id).inserted { foundTracks.append(t) }
        }

        // 2. Local album cache search
        if albums.isEmpty && !isLoadingAlbums {
            Task { [weak self] in await self?.loadAlbums() }
        }
        albums.filter {
            needle.matches($0.album) ||
            needle.matches($0.artist   ?? "") ||
            needle.matches($0.composer ?? "")
        }.forEach { mergeAlbum($0) }

        // 3. Local works-cache search
        for cached in worksCache.values {
            cached.filter {
                needle.matches($0.work) ||
                needle.matches($0.composer ?? "")
            }.forEach { mergeWork($0) }
        }

        // 4. Concurrent server searches
        let queryWords = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        // Build deduped ordered list of search terms: full query first, then
        // individual words (useful when LMS work-search requires word-level terms).
        var workTerms: [String] = [trimmed]
        if queryWords.count > 1 {
            var seen = Set<String>([trimmed])
            for word in queryWords where seen.insert(word).inserted {
                workTerms.append(word)
            }
        }

        let workTermsSnapshot = workTerms

        async let serverAlbumsTask: [Album] =
            (try? await LyrionAPI.shared.searchAlbums(term: trimmed, count: 150)) ?? []

        async let serverArtistsTask: [Artist] =
            (try? await LyrionAPI.shared.searchArtists(term: trimmed, count: 30)) ?? []

        async let serverTracksTask: [Track] =
            (try? await LyrionAPI.shared.searchTracks(term: trimmed, count: 30)) ?? []

        async let directWorksTask: [[Work]] = withThrowingTaskGroup(of: [Work].self) { group in
            for term in workTermsSnapshot {
                group.addTask { (try? await LyrionAPI.shared.getWorks(start: 0, count: 80, search: term)) ?? [] }
            }
            var all: [[Work]] = []
            for try await batch in group { all.append(batch) }
            return all
        }

        let serverAlbums = await serverAlbumsTask
        guard !Task.isCancelled else { return ([], [], [], [], [], [], []) }

        let serverWorkBatches = (try? await directWorksTask) ?? []
        guard !Task.isCancelled else { return ([], [], [], [], [], [], []) }

        let serverArtists = await serverArtistsTask
        guard !Task.isCancelled else { return ([], [], [], [], [], [], []) }

        let serverTracks = await serverTracksTask
        guard !Task.isCancelled else { return ([], [], [], [], [], [], []) }

        serverAlbums.forEach { mergeAlbum($0) }
        serverArtists.forEach { a in
            if seenArtistIDs.insert(a.id).inserted { foundArtists.append(a) }
        }

        for batch in serverWorkBatches {
            batch.filter {
                needle.matches($0.work) ||
                needle.matches($0.composer ?? "")
            }.forEach { mergeWork($0) }
        }

        // Merge server track results (fills track results when songs aren't pre-loaded).
        serverTracks.forEach { t in
            if seenTrackIDs.insert(t.id).inserted { foundTracks.append(t) }
        }

        // 5. Sort and cap
        let sortedComposers = foundComposers.sorted {
            $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
        }
        let sortedWorks = foundWorks.sorted {
            $0.work.localizedCaseInsensitiveCompare($1.work) == .orderedAscending
        }
        let sortedAlbums = foundAlbums.sorted { lhs, rhs in
            let lExact = SearchTextNormalizer.folded(lhs.album).contains(needle.folded)
            let rExact = SearchTextNormalizer.folded(rhs.album).contains(needle.folded)
            if lExact != rExact { return lExact }
            return lhs.album.localizedCaseInsensitiveCompare(rhs.album) == .orderedAscending
        }
        let sortedArtists = foundArtists.sorted { lhs, rhs in
            let lExact = SearchTextNormalizer.folded(lhs.name).hasPrefix(needle.folded)
            let rExact = SearchTextNormalizer.folded(rhs.name).hasPrefix(needle.folded)
            if lExact != rExact { return lExact }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let sortedTracks = foundTracks.sorted { lhs, rhs in
            let lTitle = SearchTextNormalizer.folded(lhs.title).hasPrefix(needle.folded)
            let rTitle = SearchTextNormalizer.folded(rhs.title).hasPrefix(needle.folded)
            if lTitle != rTitle { return lTitle }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        let matchedGenres = genres.filter { needle.matches($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let matchedPlaylists = PlaylistStore.shared.playlists.filter { needle.matches($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return (
            Array(sortedComposers.prefix(30)),
            Array(sortedWorks.prefix(50)),
            Array(sortedAlbums.prefix(60)),
            Array(sortedArtists.prefix(20)),
            Array(sortedTracks.prefix(30)),
            Array(matchedGenres.prefix(15)),
            Array(matchedPlaylists.prefix(15))
        )
    }

    // MARK: - Cache management

    func clearCache() {
        composersLoadTask?.cancel()
        composersLoadTask = nil
        artistsLoadTask?.cancel()
        artistsLoadTask = nil
        genresLoadTask?.cancel()
        genresLoadTask = nil
        songsLoadTask?.cancel()
        songsLoadTask = nil
        songsPageTask?.cancel()
        songsPageTask = nil
        nextSongsStart = 0
        songsExhausted = false
        worksLoadTasks.values.forEach { $0.cancel() }
        tracksForWorkTasks.values.forEach { $0.cancel() }
        tracksForAlbumTasks.values.forEach { $0.cancel() }
        recentAlbumsTask?.cancel()
        recentlyPlayedTask?.cancel()
        totalsTask?.cancel()
        isLoadingComposers = false
        isLoadingWorks     = false
        isLoadingAlbums    = false
        isLoadingArtists   = false
        isLoadingSongs     = false
        error              = nil
        composers          = []
        artists            = []
        songs              = []
        albums             = []
        recentAlbums       = []
        recentlyPlayed     = []
        homeRecentlyPlayed      = []
        classicalRecentlyPlayed = []
        homeRecentAlbums        = []
        classicalRecentAlbums   = []
        totalWorks         = nil
        totalAlbums        = nil
        totalSongs         = nil
        totalArtists       = nil
        hasLoadedAllAlbums = false
        albumsLoadGeneration = UUID()
        composerCache  = nil
        artistCache    = nil
        genreCache     = nil
        genres         = []
        isLoadingGenres = false
        worksCache     = [:]
        tracksForWork  = [:]
        tracksForAlbum = [:]
        worksLoadTasks.removeAll()
        tracksForWorkTasks.removeAll()
        tracksForAlbumTasks.removeAll()
        recentAlbumsTask     = nil
        recentlyPlayedTask   = nil
        totalsTask           = nil
        recentAlbumsTaskID   = nil
        recentlyPlayedTaskID = nil
    }

    func refresh() async {
        clearCache()
        albums               = []
        recentAlbums         = []
        recentlyPlayed       = []
        totalWorks           = nil
        totalAlbums          = nil
        albumsLoadGeneration = UUID()
        hasLoadedAllAlbums   = false
        async let composersReload:      Void = loadComposers()
        async let recentAlbumsReload:   Void = loadRecentAlbums(force: true)
        async let recentlyPlayedReload: Void = loadRecentlyPlayed(force: true)
        async let totalsReload:         Void = loadTotals()
        _ = await (composersReload, recentAlbumsReload, recentlyPlayedReload, totalsReload)
    }

    // MARK: - Error message formatting

    private func userFriendlyErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Server is responding slowly. Please check your connection."
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection. Check WiFi or cellular."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot reach the server. Check the server address."
            default:
                return "Connection problem: \(error.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
