import Foundation

// Persistent disk cache for the full OpenOpus composer catalogue.
//
// On first access (cold start, no cache file) fetches all 26 letter endpoints
// in parallel and writes `Caches/oo_composer_cache.json`.
// On subsequent accesses within 7 days the cache file is returned instantly.
// When the cache is stale (age > 7 days) the stored list is returned immediately
// while a background task silently refreshes it.

actor OOComposerCache {

    static let shared = OOComposerCache()

    private let cacheURL: URL
    private let ttl: TimeInterval = 7 * 24 * 3600   // 7 days

    private var inMemory: [OOComposer]?
    private var refreshTask: Task<Void, Never>?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = caches.appendingPathComponent("oo_composer_cache.json")
    }

    // MARK: - Public API

    /// Returns the cached composer list, fetching from disk or network as needed.
    /// Always returns promptly — stale caches trigger a silent background refresh.
    func composers() async -> [OOComposer] {
        if let mem = inMemory { return mem }

        if let (list, age) = loadFromDisk() {
            inMemory = list
            if age > ttl {
                scheduleBackgroundRefresh()
            }
            return list
        }

        // Nothing on disk — block until we have a fresh list.
        let fresh = await fetchAll()
        inMemory = fresh
        if !fresh.isEmpty { saveToDisk(fresh) }
        return fresh
    }

    /// Returns a folded-name → epoch dictionary for cross-referencing LMS composers.
    /// Keys are normalised with SearchTextNormalizer.folded so matching is
    /// case- and diacritic-insensitive.
    func epochByName() async -> [String: OOEpoch] {
        let list = await composers()
        var dict: [String: OOEpoch] = [:]
        for c in list {
            guard let epochStr = c.epoch,
                  let epoch = OOEpoch(rawValue: epochStr) else { continue }
            dict[SearchTextNormalizer.folded(c.name)] = epoch
            let completeFolded = SearchTextNormalizer.folded(c.complete_name)
            if dict[completeFolded] == nil { dict[completeFolded] = epoch }
        }
        return dict
    }

    /// Forces an immediate refresh (e.g. pull-to-refresh).
    func refresh() async {
        let fresh = await fetchAll()
        guard !fresh.isEmpty else { return }
        inMemory = fresh
        saveToDisk(fresh)
    }

    // MARK: - Internals

    private func scheduleBackgroundRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await self.refresh()
            self.refreshTask = nil
        }
    }

    // MARK: Network fetch

    private func fetchAll() async -> [OOComposer] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return await withTaskGroup(of: [OOComposer].self) { group in
            for letter in letters {
                group.addTask {
                    (try? await OpenOpusService.shared.composersByLetter(letter)) ?? []
                }
            }
            var seen = Set<String>()
            var all: [OOComposer] = []
            all.reserveCapacity(2000)
            for await batch in group {
                for c in batch where seen.insert(c.id).inserted {
                    all.append(c)
                }
            }
            return all.sorted { $0.name < $1.name }
        }
    }

    // MARK: Disk I/O

    private struct Payload: Codable {
        let composers: [OOComposer]
        let fetchedAt: Date
    }

    private func loadFromDisk() -> ([OOComposer], TimeInterval)? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(payload.fetchedAt)
        return (payload.composers, age)
    }

    private func saveToDisk(_ composers: [OOComposer]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(composers: composers, fetchedAt: Date())) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
