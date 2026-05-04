import Foundation
import Combine
import UIKit

@MainActor
final class LibraryViewModel: ObservableObject {

    static let shared = LibraryViewModel()

    @Published var composers: [Composer] = []
    @Published var albums: [Album] = []
    @Published var recentAlbums: [Album] = []
    @Published var recentlyPlayed: [Album] = []
    @Published var isLoadingComposers: Bool = false
    @Published var isLoadingWorks: Bool = false
    @Published var isLoadingAlbums: Bool = false
    @Published var error: String? = nil
    @Published var totalWorks:  Int? = nil
    @Published var totalAlbums: Int? = nil

    private var composerCache: [Composer]? = nil

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
    private var recentAlbumsTaskID: UUID?
    private var recentlyPlayedTaskID: UUID?

    private let pageSize = 100

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
                self?.worksLoadTasks.removeAll()
                self?.tracksForWorkTasks.removeAll()
                self?.tracksForAlbumTasks.removeAll()
                self?.recentAlbumsTask = nil
                self?.recentlyPlayedTask = nil
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
        guard totalWorks == nil || totalAlbums == nil else { return }
        async let worksCount:  Int? = try? LyrionAPI.shared.getWorksCount()
        async let albumsCount: Int? = try? LyrionAPI.shared.getAlbumsCount()
        let (w, a) = await (worksCount, albumsCount)
        if let w { totalWorks  = w }
        if let a { totalAlbums = a }
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
        if !force, let existing = recentAlbumsTask {
            do { recentAlbums = try await existing.value } catch { }
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
            recentAlbums = try await task.value
        } catch is CancellationError {
            // Ignore.
        } catch {
            self.error = userFriendlyErrorMessage(for: error)
        }
    }

    func loadRecentlyPlayed(force: Bool = false) async {
        if !force && !recentlyPlayed.isEmpty { return }

        let local = PlaybackHistoryStore.shared.recentlyPlayedAlbums(limit: 20)
        recentlyPlayed = local

        if !force, let existing = recentlyPlayedTask {
            do {
                let server = try await existing.value
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

    func search(query: String) async -> (composers: [Composer], works: [Work], albums: [Album]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], [], []) }

        let needle = SearchTextNormalizer.Needle(trimmed)

        var foundComposers: [Composer] = []
        var foundWorks:     [Work]     = []
        var foundAlbums:    [Album]    = []
        var seenComposerIDs = Set<Int>()
        var seenWorkIDs     = Set<Int>()
        var seenWorkKeys    = Set<String>()
        var seenAlbumIDs    = Set<Int>()

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

        // 1. Local composer search (always complete — paginated on load)
        if composers.isEmpty { await loadComposers() }
        composers.filter { needle.matches($0.artist) }.forEach { mergeComposer($0) }

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
        guard !Task.isCancelled else { return ([], [], []) }

        let serverWorkBatches = (try? await directWorksTask) ?? []
        guard !Task.isCancelled else { return ([], [], []) }

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

        return (
            Array(sortedComposers.prefix(30)),
            Array(sortedWorks.prefix(50)),
            Array(sortedAlbums.prefix(60))
        )
    }

    // MARK: - Cache management

    func clearCache() {
        composersLoadTask?.cancel()
        composersLoadTask = nil
        worksLoadTasks.values.forEach { $0.cancel() }
        tracksForWorkTasks.values.forEach { $0.cancel() }
        tracksForAlbumTasks.values.forEach { $0.cancel() }
        recentAlbumsTask?.cancel()
        recentlyPlayedTask?.cancel()
        isLoadingComposers = false
        isLoadingWorks     = false
        isLoadingAlbums    = false
        composerCache  = nil
        worksCache     = [:]
        tracksForWork  = [:]
        tracksForAlbum = [:]
        worksLoadTasks.removeAll()
        tracksForWorkTasks.removeAll()
        tracksForAlbumTasks.removeAll()
        recentAlbumsTask     = nil
        recentlyPlayedTask   = nil
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
