import Foundation

// Maps LMS albums to OpenOpus works via multi-signal candidate scoring.
// Candidates are ranked by confidence and stored per OO work ID.
// User corrections live in OOUserLinkOverrideStore (separate file) and
// survive cache rebuilds.

@MainActor
final class LMSLibraryLinker: ObservableObject {

    static let shared = LMSLibraryLinker()
    private init() { loadFromDisk() }

    // OO work ID → ranked candidates (highest confidence first)
    @Published private(set) var candidatesByWork: [String: [WorkRecordingCandidate]] = [:]

    // LMS album ID → candidates
    private(set) var candidatesByAlbum: [Int: [WorkRecordingCandidate]] = [:]

    // Performer name → role string (from performerRoles endpoint)
    private(set) var performerRoles: [String: String] = [:]

    // Albums confirmed not to match any OO work (avoid re-querying)
    private var noMatchAlbums: Set<Int> = []

    // Diagnostics
    let cacheVersion = "v2"
    private(set) var lastRebuilt: Date? = nil

    private var linkTask: Task<Void, Never>? = nil
    @Published private(set) var isLinking: Bool = false
    @Published private(set) var linkedCount: Int = 0

    // MARK: - Lookups

    func topCandidate(forWorkID id: String) -> WorkRecordingCandidate? {
        // User-confirmed/created candidates always rank first
        let overrides = OOUserLinkOverrideStore.shared
        let candidates = candidatesByWork[id] ?? []
        // FIXED: pass trackIDs so the v2 key disambiguates multiple work appearances on same album
        if let confirmed = candidates.first(where: { overrides.isConfirmed(workID: id, albumID: $0.lmsAlbumID, trackIDs: $0.lmsTrackIDs) }) {
            return confirmed
        }
        return candidates.first(where: { !overrides.isRejected(workID: id, albumID: $0.lmsAlbumID, trackIDs: $0.lmsTrackIDs) })
    }

    func candidates(forWorkID id: String) -> [WorkRecordingCandidate] {
        let overrides = OOUserLinkOverrideStore.shared
        return (candidatesByWork[id] ?? []).filter {
            !overrides.isRejected(workID: id, albumID: $0.lmsAlbumID, trackIDs: $0.lmsTrackIDs) // FIXED: v2 key
        }
    }

    func candidates(forAlbumID id: Int) -> [WorkRecordingCandidate] {
        candidatesByAlbum[id] ?? []
    }

    func isInLibrary(workID: String) -> Bool {
        topCandidate(forWorkID: workID) != nil
    }

    func role(for performerName: String) -> String? {
        performerRoles[performerName]
    }

    // MARK: - Quick guess for Now Playing

    func guessWork(title: String, composerName: String) async -> OOGuessResult? {
        guard !title.isEmpty, !composerName.isEmpty else { return nil }
        let req = OOGuessRequest(title: title, composer: composerName)
        do {
            let results = try await OpenOpusService.shared.guessWorks([req])
            guard let result = results.first, result.guessed != nil else { return nil }
            return result
        } catch {
            linkerLog("guessWork failed for '\(title)': \(error)")
            return nil
        }
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

    /// Fetches the full album list from LMS and starts the linking job.
    /// Safe to call on every ClassicalBrowserView appear — skips the rebuild
    /// if the cache is fresh (< 6 h old) and non-empty. Never starts more
    /// than one concurrent linking job.
    func startLinkingFromLibrary() {
        guard linkTask == nil, !LyrionAPI.shared.baseURL.isEmpty else { return }
        if let rebuilt = lastRebuilt,
           Date().timeIntervalSince(rebuilt) < 6 * 3600,
           !candidatesByWork.isEmpty {
            linkerLog("Cache fresh (built \(Int(Date().timeIntervalSince(rebuilt) / 3600))h ago), skipping rebuild")
            return
        }
        isLinking = true
        linkTask = Task {
            defer { self.isLinking = false; self.linkTask = nil }
            var albums: [Album] = []
            var start = 0
            let batchSize = 500
            while !Task.isCancelled {
                do {
                    let batch = try await LyrionAPI.shared.getAlbums(start: start, count: batchSize)
                    albums.append(contentsOf: batch)
                    if batch.count < batchSize { break }
                    start += batchSize
                } catch {
                    linkerLog("startLinkingFromLibrary: album fetch failed — \(error)")
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, !albums.isEmpty else { return }
            linkerLog("startLinkingFromLibrary: \(albums.count) albums fetched, starting link pass")
            await runLinkingJob(albums: albums)
        }
    }

    func cancelLinking() {
        linkTask?.cancel()
        linkTask = nil
        isLinking = false
    }

    /// Force a full rebuild regardless of cache freshness. Cancels any in-flight job first.
    func forceRebuild() {
        linkTask?.cancel()
        linkTask = nil
        isLinking = false
        lastRebuilt = nil   // clear freshness guard
        startLinkingFromLibrary()
    }

    // MARK: - Main linking pipeline

    private func runLinkingJob(albums: [Album]) async {
        linkerLog("Starting linker job for \(albums.count) albums")
        let candidates = albums.filter {
            let hasComposer  = !($0.composer?.isEmpty ?? true)
            let alreadyLinked = candidatesByAlbum[$0.id] != nil
            let knownMissing  = noMatchAlbums.contains($0.id)
            return hasComposer && !alreadyLinked && !knownMissing
        }
        linkerLog("\(candidates.count) albums to process (filtered)")

        // Step 1: Batch-guess OO work IDs
        let batchSize = 20
        var guessedPairs: [(album: Album, workID: String)] = []
        var i = 0
        while i < candidates.count {
            guard !Task.isCancelled else {
                linkerLog("Linking cancelled during guess phase at index \(i)")
                break
            }
            let batch = Array(candidates[i..<Swift.min(i + batchSize, candidates.count)])
            let requests: [OOGuessRequest] = batch.compactMap { album in
                guard let composer = album.composer, !composer.isEmpty else { return nil }
                return OOGuessRequest(title: album.album, composer: composer)
            }
            if !requests.isEmpty {
                do {
                    let results = try await OpenOpusService.shared.guessWorks(requests)
                    for (idx, result) in results.enumerated() {
                        guard idx < batch.count else { continue }
                        let album = batch[idx]
                        if let workID = result.guessed?.id {
                            guessedPairs.append((album: album, workID: workID))
                        } else {
                            noMatchAlbums.insert(album.id)
                        }
                    }
                } catch {
                    linkerLog("guessWorks batch \(i/batchSize) failed: \(error)")
                }
            }
            i += batchSize
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        linkerLog("Guess phase complete: \(guessedPairs.count) pairs found")

        // Step 2: Fetch work detail and score each candidate
        var scored: [(candidate: WorkRecordingCandidate, album: Album)] = []
        for pair in guessedPairs {
            guard !Task.isCancelled else { break }
            do {
                let detail = try await OpenOpusService.shared.workDetail(pair.workID)
                guard let work = detail.work, let composer = detail.composer else {
                    linkerLog("workDetail \(pair.workID) missing work/composer fields")
                    continue
                }
                let group = recordingGroup(from: pair.album)
                let candidate = scoreCandidate(
                    group: group,
                    album: pair.album,
                    ooWork: work,
                    ooComposer: composer
                )
                guard candidate.confidence > 0.30 else {
                    linkerLog("Rejected \(pair.album.album) → \(work.title) (confidence \(String(format: "%.2f", candidate.confidence)): \(candidate.matchReason))")
                    noMatchAlbums.insert(pair.album.id)
                    continue
                }
                insertCandidate(candidate)
                scored.append((candidate: candidate, album: pair.album))
                linkedCount = candidatesByWork.count
            } catch {
                linkerLog("workDetail fetch failed for workID \(pair.workID): \(error)")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        linkerLog("Scoring phase complete: \(scored.count) candidates inserted")

        // Step 3: Backfill track IDs for top-confidence candidates (limited to 60)
        let topCandidates = scored
            .filter { $0.candidate.confidence >= 0.65 }
            .sorted { $0.candidate.confidence > $1.candidate.confidence }
            .prefix(60)

        for item in topCandidates {
            guard !Task.isCancelled else { break }
            guard candidatesByAlbum[item.album.id]?.first?.lmsTrackIDs.isEmpty ?? true else {
                continue // already have track IDs
            }
            do {
                let tracks = try await LyrionAPI.shared.getTracksForAlbum(albumID: item.album.id)
                guard !tracks.isEmpty else { continue }
                let trackIDs = tracks.map(\.id)
                // Update candidate with populated track IDs
                updateTrackIDs(
                    trackIDs,
                    forCandidateID: item.candidate.id,
                    workID: item.candidate.openOpusWorkID,
                    albumID: item.album.id
                )
            } catch {
                linkerLog("Track fetch failed for album \(item.album.id): \(error)")
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        await resolvePerformerRoles(from: albums)
        lastRebuilt = Date()
        saveToDisk()
        linkerLog("Linker job complete. \(linkedCount) works indexed.")
    }

    // MARK: - Scoring

    private func scoreCandidate(
        group: RecordingGroup,
        album: Album,
        ooWork: OOWork,
        ooComposer: OOComposer
    ) -> WorkRecordingCandidate {
        let result = CandidateScorer.score(
            albumTitle:    group.albumName,
            albumComposer: group.composer ?? "",
            albumArtist:   group.performer ?? "",
            ooTitle:       ooWork.title,
            ooComposerName: ooComposer.complete_name,
            lmsWorkTag:    nil    // album-level only; track-level work tags handled separately
        )

        return WorkRecordingCandidate(
            id: UUID().uuidString,
            openOpusWorkID: ooWork.id,
            composerName: ooComposer.complete_name,
            workTitle: ooWork.title,
            lmsAlbumID: group.albumID,
            lmsAlbumName: group.albumName,
            lmsTrackIDs: [],    // populated in track-fetch pass
            artworkTrackID: album.artwork_track_id,
            confidence: result.confidence,
            matchReason: result.matchReason,
            source: .indexed,
            userOverride: false,
            performerSummary: group.performerSummary.isEmpty ? nil : group.performerSummary
        )
    }

    // MARK: - Candidate management

    private func insertCandidate(_ candidate: WorkRecordingCandidate) {
        // Preserve userOverride state from any existing entry for same album
        func preservingOverride(new: WorkRecordingCandidate, old: WorkRecordingCandidate?) -> WorkRecordingCandidate {
            guard let old, old.userOverride else { return new }
            var c = new; c.userOverride = true; return c
        }

        var byWork = candidatesByWork[candidate.openOpusWorkID] ?? []
        let existingWork = byWork.first(where: { $0.lmsAlbumID == candidate.lmsAlbumID })
        byWork.removeAll { $0.lmsAlbumID == candidate.lmsAlbumID }
        byWork.append(preservingOverride(new: candidate, old: existingWork))
        // Sort: user-overrides first, then by confidence
        byWork.sort {
            if $0.userOverride != $1.userOverride { return $0.userOverride }
            return $0.confidence > $1.confidence
        }
        candidatesByWork[candidate.openOpusWorkID] = byWork

        var byAlbum = candidatesByAlbum[candidate.lmsAlbumID] ?? []
        let existingAlbum = byAlbum.first(where: { $0.openOpusWorkID == candidate.openOpusWorkID })
        byAlbum.removeAll { $0.openOpusWorkID == candidate.openOpusWorkID }
        byAlbum.append(preservingOverride(new: candidate, old: existingAlbum))
        byAlbum.sort { $0.confidence > $1.confidence }
        candidatesByAlbum[candidate.lmsAlbumID] = byAlbum
    }

    private func updateTrackIDs(_ ids: [Int],
                                forCandidateID cid: String,
                                workID: String,
                                albumID: Int) {
        func update(_ c: WorkRecordingCandidate) -> WorkRecordingCandidate {
            guard c.id == cid else { return c }
            return WorkRecordingCandidate(
                id: c.id,
                openOpusWorkID: c.openOpusWorkID,
                composerName: c.composerName,
                workTitle: c.workTitle,
                lmsAlbumID: c.lmsAlbumID,
                lmsAlbumName: c.lmsAlbumName,
                lmsTrackIDs: ids,
                artworkTrackID: c.artworkTrackID,
                confidence: c.confidence,
                matchReason: c.matchReason,
                source: c.source,
                userOverride: c.userOverride,
                performerSummary: c.performerSummary
            )
        }
        candidatesByWork[workID] = candidatesByWork[workID]?.map(update)
        candidatesByAlbum[albumID] = candidatesByAlbum[albumID]?.map(update)
    }

    // MARK: - Build RecordingGroup from Album

    private func recordingGroup(from album: Album) -> RecordingGroup {
        let artistField   = album.artist ?? ""
        let composerField = album.composer ?? ""
        let (conductor, orchestra) = parseConductorOrchestra(artistField)

        return RecordingGroup(
            id: "\(album.id):\(album.album)",
            workTitle: album.album,
            composer: composerField.isEmpty ? nil : composerField,
            tracks: [],
            albumID: album.id,
            albumName: album.album,
            artworkTrackID: album.artwork_track_id,
            conductor: conductor,
            orchestra: orchestra,
            performer: artistField.isEmpty ? nil : artistField
        )
    }

    private func parseConductorOrchestra(_ artist: String) -> (conductor: String?, orchestra: String?) {
        let orchestraKeywords = ["orchestra", "philharmonic", "symphony", "chamber",
                                  "ensemble", "quartet", "quintet", "trio", "sinfonia",
                                  "consort", "band", "collegium"]
        let parts = artist.components(separatedBy: CharacterSet(charactersIn: "/;"))
                          .map { $0.trimmingCharacters(in: .whitespaces) }
                          .filter { !$0.isEmpty }
        var conductor: String? = nil
        var orchestra: String? = nil
        for part in parts {
            let lower = part.lowercased()
            if orchestraKeywords.contains(where: { lower.contains($0) }) {
                orchestra = part
            } else if conductor == nil {
                conductor = part
            }
        }
        return (conductor, orchestra)
    }

    // MARK: - Performer role resolution

    private func resolvePerformerRoles(from albums: [Album]) async {
        let names = Set(albums.compactMap(\.artist))
            .subtracting(Set(performerRoles.keys))
            .filter { !$0.isEmpty }
        let nameArray = Array(names.prefix(200))
        var i = 0
        while i < nameArray.count {
            guard !Task.isCancelled else { break }
            let batch = Array(nameArray[i..<Swift.min(i + 20, nameArray.count)])
            do {
                let performers = try await OpenOpusService.shared.performerRoles(names: batch)
                for p in performers {
                    if let role = p.role, !role.isEmpty {
                        performerRoles[p.name] = role
                    }
                }
            } catch {
                linkerLog("performerRoles batch failed: \(error)")
            }
            i += 20
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - User overrides (delegates to OOUserLinkOverrideStore)

    // FIXED: trackIDs param forwards v2 key so overrides are disambiguated per track subset
    func confirmCandidate(workID: String, albumID: Int, trackIDs: [Int] = []) {
        OOUserLinkOverrideStore.shared.confirm(workID: workID, albumID: albumID, trackIDs: trackIDs)
        objectWillChange.send()
    }

    func rejectCandidate(workID: String, albumID: Int, trackIDs: [Int] = []) {
        OOUserLinkOverrideStore.shared.reject(workID: workID, albumID: albumID, trackIDs: trackIDs)
        objectWillChange.send()
    }

    // MARK: - Persistence

    private struct Cache: Codable {
        var candidatesByWork: [String: [CandidateDTO]]
        var performerRoles: [String: String]
        var noMatchAlbums: [Int]
        var lastRebuilt: Date?

        struct CandidateDTO: Codable {
            let id: String
            let openOpusWorkID: String
            let composerName: String
            let workTitle: String
            let lmsAlbumID: Int
            let lmsAlbumName: String
            let lmsTrackIDs: [Int]
            let artworkTrackID: String?
            let confidence: Double
            let matchReason: String
            let source: WorkRecordingCandidate.MatchSource
            var userOverride: Bool
            var performerSummary: String?
        }
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oo_linker_v2.json")
    }

    private func saveToDisk() {
        let dtos = candidatesByWork.mapValues { candidates in
            candidates.map { c in
                Cache.CandidateDTO(
                    id: c.id,
                    openOpusWorkID: c.openOpusWorkID,
                    composerName: c.composerName,
                    workTitle: c.workTitle,
                    lmsAlbumID: c.lmsAlbumID,
                    lmsAlbumName: c.lmsAlbumName,
                    lmsTrackIDs: c.lmsTrackIDs,
                    artworkTrackID: c.artworkTrackID,
                    confidence: c.confidence,
                    matchReason: c.matchReason,
                    source: c.source,
                    userOverride: c.userOverride,
                    performerSummary: c.performerSummary
                )
            }
        }
        let cache = Cache(
            candidatesByWork: dtos,
            performerRoles: performerRoles,
            noMatchAlbums: Array(noMatchAlbums),
            lastRebuilt: lastRebuilt
        )
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomicWrite)
        } catch {
            linkerLog("saveToDisk failed: \(error) — linked data will be lost on next launch")
        }
    }

    private func loadFromDisk() {
        guard let data = (try? Data(contentsOf: cacheURL)) else {
            linkerLog("No linker cache found at \(cacheURL.lastPathComponent)")
            return
        }
        do {
            let cache = try JSONDecoder().decode(Cache.self, from: data)
            var byWork:  [String: [WorkRecordingCandidate]] = [:]
            var byAlbum: [Int: [WorkRecordingCandidate]] = [:]
            for (workID, dtos) in cache.candidatesByWork {
                let candidates = dtos.map { d in
                    WorkRecordingCandidate(
                        id: d.id,
                        openOpusWorkID: d.openOpusWorkID,
                        composerName: d.composerName,
                        workTitle: d.workTitle,
                        lmsAlbumID: d.lmsAlbumID,
                        lmsAlbumName: d.lmsAlbumName,
                        lmsTrackIDs: d.lmsTrackIDs,
                        artworkTrackID: d.artworkTrackID,
                        confidence: d.confidence,
                        matchReason: d.matchReason,
                        source: d.source,
                        userOverride: d.userOverride,
                        performerSummary: d.performerSummary
                    )
                }
                byWork[workID] = candidates
                for c in candidates {
                    var list = byAlbum[c.lmsAlbumID] ?? []
                    list.append(c)
                    byAlbum[c.lmsAlbumID] = list
                }
            }
            candidatesByWork  = byWork
            candidatesByAlbum = byAlbum
            performerRoles    = cache.performerRoles
            noMatchAlbums     = Set(cache.noMatchAlbums)
            lastRebuilt       = cache.lastRebuilt
            linkedCount       = byWork.count
            linkerLog("Loaded cache: \(linkedCount) works, \(performerRoles.count) performer roles")
        } catch {
            linkerLog("loadFromDisk failed: \(error) — starting with empty index")
        }
    }
}

// MARK: - Comparable clamp helper (also used in ClassicalMatchingModels)

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}
