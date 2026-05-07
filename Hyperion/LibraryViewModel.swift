import Foundation
import Combine
import UIKit

@MainActor
final class LibraryViewModel: ObservableObject {

    static let shared = LibraryViewModel()

    @Published var composers: [Composer] = []
    @Published var artists: [Artist] = []
    @Published var songs: [Track] = []
    @Published var albums: [Album] = []
    @Published var recentAlbums: [Album] = []
    @Published var recentlyPlayed: [Album] = []
    @Published var genres: [Genre] = []
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

    private var composerCache: [Composer]? = nil
    private var artistCache: [Artist]? = nil
    private var genreCache: [Genre]? = nil
    private var artistsLoadTask: Task<[Artist], Error>?
    private var genresLoadTask: Task<[Genre], Error>?
    private var songsLoadTask: Task<[Track], Error>?

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
            await self.loadSongs()
            var loadedAlbums = (try? await albumsResult) ?? []
            loadedAlbums.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
            return ArtistDetailResult(albums: loadedAlbums, songs: self.songs)
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

    func loadSongs() async {
        if !songs.isEmpty {
            print("[LoadSongs] Already loaded (\(songs.count) songs) — skipping")
            return
        }
        if let existing = songsLoadTask {
            // Caller joining an in-flight load: wait for it, then ensure songs is populated.
            print("[LoadSongs] In-flight load already running — joining it")
            _ = try? await existing.value
            return
        }
        print("[LoadSongs] Starting full library song load")
        isLoadingSongs = true
        let pageSize = self.pageSize
        let task = Task<[Track], Error> {
            var all: [Track] = []
            var start = 0
            while true {
                try Task.checkCancellation()
                let batch = try await LyrionAPI.shared.getAllSongs(start: start, count: pageSize)
                all.append(contentsOf: batch)
                // Publish the first page immediately so the UI shows something fast.
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
            let all = try await task.value
            songs = all
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
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
                recentAlbums = albums
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
            recentAlbums = albums
        } catch is CancellationError {
            // Ignore.
        } catch {
            guard recentAlbumsTaskID == taskID else { return }
            self.error = userFriendlyErrorMessage(for: error)
        }
    }

    func loadRecentlyPlayed(force: Bool = false) async {
        if !force && !recentlyPlayed.isEmpty { return }

        let local = PlaybackHistoryStore.shared.recentlyPlayedAlbums(limit: 20)
        recentlyPlayed = local

        if force {
            recentlyPlayedTask?.cancel()
            recentlyPlayedTask = nil
            recentlyPlayedTaskID = nil
        } else if let existing = recentlyPlayedTask {
            do {
                let server = try await existing.value
                guard !Task.isCancelled else { return }
                recentlyPlayed = mergeRecentlyPlayed(local: local, server: server, limit: 20)
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
            recentlyPlayed = mergeRecentlyPlayed(local: local, server: server, limit: 20)
        } catch is CancellationError {
            // Ignore.
        } catch {
            // Non-fatal: not all LMS versions expose play history reliably.
        }
    }

    func recordPlayback(_ track: Track) {
        PlaybackHistoryStore.shared.recordPlayback(of: track)
        recentlyPlayed = mergeRecentlyPlayed(
            local:  PlaybackHistoryStore.shared.recentlyPlayedAlbums(limit: 20),
            server: recentlyPlayed,
            limit:  20
        )
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

        serverAlbums.forEach { mergeAlbum($0) }

        for batch in serverWorkBatches {
            batch.filter {
                needle.matches($0.work) ||
                needle.matches($0.composer ?? "")
            }.forEach { mergeWork($0) }
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
