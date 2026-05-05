import Foundation

// Maps LMS albums to OpenOpus work IDs by sending batched guessWorks requests,
// then persists the mapping to disk. Performer role resolution is done in
// a second pass using the performerRoles endpoint.

@MainActor
final class LMSLibraryLinker {

    static let shared = LMSLibraryLinker()
    private init() { loadFromDisk() }

    // album.id (as String) → OO work ID
    private(set) var workIDByAlbum: [String: String] = [:]
    // album.id (as String) → definitely not found flag (so we don't retry)
    private var notFoundAlbums: Set<String> = []
    // performer name → role string
    private(set) var performerRoles: [String: String] = [:]

    private var linkTask: Task<Void, Never>? = nil
    private(set) var isLinking: Bool = false
    private(set) var linkedCount: Int = 0

    // MARK: - Lookups

    /// Returns the OpenOpus work ID for the given LMS album ID, or nil if unknown.
    func workID(forAlbumID id: Int) -> String? {
        workIDByAlbum[String(id)]
    }

    /// Returns the performer role for the given name, or nil if unknown.
    func role(for performerName: String) -> String? {
        performerRoles[performerName]
    }

    // MARK: - Quick guess for Now Playing

    /// Tries to find the OpenOpus work for the currently-playing track using
    /// the Work Guesser API. Returns nil on no match or network error.
    func guessWork(title: String, composerName: String) async -> OOGuessResult? {
        guard !title.isEmpty, !composerName.isEmpty else { return nil }
        let req = OOGuessRequest(title: title, composer: composerName)
        guard let results = try? await OpenOpusService.shared.guessWorks([req]),
              let result = results.first,
              result.work != nil else { return nil }
        return result
    }

    // MARK: - Background library linker

    func startLinking(albums: [Album]) {
        guard linkTask == nil else { return }
        isLinking = true
        linkTask = Task {
            await self.runLinkingJob(albums: albums)
            self.isLinking = false
            self.linkTask  = nil
        }
    }

    func cancelLinking() {
        linkTask?.cancel()
        linkTask = nil
        isLinking = false
    }

    private func runLinkingJob(albums: [Album]) async {
        let candidates = albums.filter {
            let hasComposer = !($0.composer?.isEmpty ?? true)
            let alreadyLinked = workIDByAlbum[String($0.id)] != nil
            let knownMissing  = notFoundAlbums.contains(String($0.id))
            return hasComposer && !alreadyLinked && !knownMissing
        }

        let batchSize = 20
        var i = 0
        while i < candidates.count {
            guard !Task.isCancelled else { break }
            let batch = Array(candidates[i..<Swift.min(i + batchSize, candidates.count)])
            let requests: [OOGuessRequest] = batch.compactMap { album in
                guard let composer = album.composer, !composer.isEmpty else { return nil }
                return OOGuessRequest(title: album.album, composer: composer)
            }
            if !requests.isEmpty,
               let results = try? await OpenOpusService.shared.guessWorks(requests) {
                for (idx, result) in results.enumerated() {
                    guard idx < batch.count else { continue }
                    let albumKey = String(batch[idx].id)
                    if let workID = result.work?.id {
                        workIDByAlbum[albumKey] = workID
                    } else {
                        notFoundAlbums.insert(albumKey)
                    }
                }
            }
            linkedCount = workIDByAlbum.count
            i += batchSize
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        await resolvePerformerRoles(from: albums)
        saveToDisk()
    }

    private func resolvePerformerRoles(from albums: [Album]) async {
        let names = Set(albums.compactMap(\.artist))
            .subtracting(Set(performerRoles.keys))
            .filter { !$0.isEmpty }
        let nameArray = Array(names.prefix(200))
        var i = 0
        while i < nameArray.count {
            guard !Task.isCancelled else { break }
            let batch = Array(nameArray[i..<Swift.min(i + 20, nameArray.count)])
            if let performers = try? await OpenOpusService.shared.performerRoles(names: batch) {
                for p in performers {
                    if let role = p.role, !role.isEmpty {
                        performerRoles[p.name] = role
                    }
                }
            }
            i += 20
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Persistence

    private struct Cache: Codable {
        var workIDByAlbum: [String: String]
        var notFoundAlbums: [String]     // Set → Array for Codable
        var performerRoles: [String: String]
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oo_linker_cache.json")
    }

    private func saveToDisk() {
        let cache = Cache(
            workIDByAlbum: workIDByAlbum,
            notFoundAlbums: Array(notFoundAlbums),
            performerRoles: performerRoles
        )
        try? JSONEncoder().encode(cache).write(to: cacheURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        workIDByAlbum  = cache.workIDByAlbum
        notFoundAlbums = Set(cache.notFoundAlbums)
        performerRoles = cache.performerRoles
        linkedCount    = workIDByAlbum.count
    }
}
