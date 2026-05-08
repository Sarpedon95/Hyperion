import Foundation

// Persists user corrections to OpenOpus↔LMS links in a separate file
// (oo_user_link_overrides.json) that is never overwritten by the linker.
//
// Rules:
//   confirmed — user says this IS correct; always shown first
//   rejected  — user says this is NOT correct; never shown again
//   created   — user manually created this link
//
// KEY SCHEME (v2)
// ──────────────
// A single work can appear on the same album more than once when the album
// contains e.g. both a complete recording and a highlights excerpt of the
// same symphony. To avoid one user override clobbering another on the same
// work+album, the key now embeds the sorted LMS track IDs:
//
//   "\(workID):\(albumID):\(sortedTrackIDs.joined(","))"
//
// An album-level override (no specific tracks, e.g. user-created from the
// album detail view) uses an empty track-list suffix:
//
//   "\(workID):\(albumID):"
//
// Lookup always checks the exact-track key first, then falls back to the
// album-level key, so pre-v2 overrides (stored with lmsTrackIDs=[]) continue
// to work without any file migration.

@MainActor
final class OOUserLinkOverrideStore {

    static let shared = OOUserLinkOverrideStore()
    private init() { load() }

    struct Override: Codable, Identifiable {
        enum Action: String, Codable { case confirmed, rejected, created }
        let id: String          // UUID
        let openOpusWorkID: String
        let lmsAlbumID: Int
        // FIXED: include track IDs in the stored record to disambiguate
        // multiple appearances of the same work on the same album.
        let lmsTrackIDs: [Int]
        let action: Action
        let timestamp: Date
        var note: String?

        // Custom decoder keeps pre-v2 records readable (lmsTrackIDs missing → []).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id            = try  c.decode(String.self,          forKey: .id)
            openOpusWorkID = try c.decode(String.self,          forKey: .openOpusWorkID)
            lmsAlbumID    = try  c.decode(Int.self,             forKey: .lmsAlbumID)
            lmsTrackIDs   = (try? c.decode([Int].self,          forKey: .lmsTrackIDs)) ?? []
            action        = try  c.decode(Action.self,          forKey: .action)
            timestamp     = try  c.decode(Date.self,            forKey: .timestamp)
            note          = try? c.decode(String.self,          forKey: .note)
        }

        init(id: String, openOpusWorkID: String, lmsAlbumID: Int,
             lmsTrackIDs: [Int], action: Action, timestamp: Date, note: String?) {
            self.id             = id
            self.openOpusWorkID = openOpusWorkID
            self.lmsAlbumID     = lmsAlbumID
            self.lmsTrackIDs    = lmsTrackIDs
            self.action         = action
            self.timestamp      = timestamp
            self.note           = note
        }
    }

    private(set) var overrides: [Override] = []

    // Quick lookup sets — keyed by the v2 scheme (see module comment above).
    private var confirmedKeys: Set<String>  = []
    private var rejectedKeys:  Set<String>  = []

    // MARK: - Queries

    // FIXED: trackIDs param disambiguates candidates that share workID+albumID
    func isConfirmed(workID: String, albumID: Int, trackIDs: [Int] = []) -> Bool {
        // Exact-track key first; fall back to album-level (empty track list).
        confirmedKeys.contains(exactKey(workID, albumID, trackIDs)) ||
        confirmedKeys.contains(albumKey(workID, albumID))
    }

    // FIXED: trackIDs param disambiguates candidates that share workID+albumID
    func isRejected(workID: String, albumID: Int, trackIDs: [Int] = []) -> Bool {
        rejectedKeys.contains(exactKey(workID, albumID, trackIDs)) ||
        rejectedKeys.contains(albumKey(workID, albumID))
    }

    func action(workID: String, albumID: Int, trackIDs: [Int] = []) -> Override.Action? {
        overrides.last(where: {
            $0.openOpusWorkID == workID && $0.lmsAlbumID == albumID &&
            (trackIDs.isEmpty || $0.lmsTrackIDs.isEmpty || $0.lmsTrackIDs.sorted() == trackIDs.sorted())
        })?.action
    }

    // MARK: - Mutations

    func confirm(workID: String, albumID: Int, trackIDs: [Int] = [], note: String? = nil) {
        upsert(Override(
            id: UUID().uuidString,
            openOpusWorkID: workID,
            lmsAlbumID: albumID,
            lmsTrackIDs: trackIDs,
            action: .confirmed,
            timestamp: Date(),
            note: note
        ))
    }

    func reject(workID: String, albumID: Int, trackIDs: [Int] = [], note: String? = nil) {
        upsert(Override(
            id: UUID().uuidString,
            openOpusWorkID: workID,
            lmsAlbumID: albumID,
            lmsTrackIDs: trackIDs,
            action: .rejected,
            timestamp: Date(),
            note: note
        ))
    }

    func create(workID: String, albumID: Int, trackIDs: [Int] = [], note: String? = nil) {
        upsert(Override(
            id: UUID().uuidString,
            openOpusWorkID: workID,
            lmsAlbumID: albumID,
            lmsTrackIDs: trackIDs,
            action: .created,
            timestamp: Date(),
            note: note
        ))
    }

    func remove(workID: String, albumID: Int, trackIDs: [Int] = []) {
        if trackIDs.isEmpty {
            // Remove all overrides for this work+album regardless of track subset.
            overrides.removeAll { $0.openOpusWorkID == workID && $0.lmsAlbumID == albumID }
        } else {
            overrides.removeAll {
                $0.openOpusWorkID == workID && $0.lmsAlbumID == albumID &&
                $0.lmsTrackIDs.sorted() == trackIDs.sorted()
            }
        }
        rebuildIndex()
        save()
    }

    // MARK: - Private key helpers

    // FIXED: v2 key — workID:albumID:t1,t2,t3 (tracks sorted ascending)
    private func exactKey(_ workID: String, _ albumID: Int, _ trackIDs: [Int]) -> String {
        "\(workID):\(albumID):\(trackIDs.sorted().map(String.init).joined(separator: ","))"
    }

    // Album-level key — matches any candidate for this work+album regardless of tracks.
    private func albumKey(_ workID: String, _ albumID: Int) -> String {
        "\(workID):\(albumID):"
    }

    private func upsert(_ override: Override) {
        // Remove any existing override with the same work+album+tracks combination.
        overrides.removeAll {
            $0.openOpusWorkID == override.openOpusWorkID &&
            $0.lmsAlbumID     == override.lmsAlbumID &&
            $0.lmsTrackIDs.sorted() == override.lmsTrackIDs.sorted()
        }
        overrides.append(override)
        rebuildIndex()
        save()
    }

    private func rebuildIndex() {
        confirmedKeys = Set(overrides.filter { $0.action == .confirmed || $0.action == .created }
                                     .map { exactKey($0.openOpusWorkID, $0.lmsAlbumID, $0.lmsTrackIDs) })
        rejectedKeys  = Set(overrides.filter { $0.action == .rejected }
                                     .map { exactKey($0.openOpusWorkID, $0.lmsAlbumID, $0.lmsTrackIDs) })
    }

    // MARK: - Persistence

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oo_user_link_overrides.json")
    }

    private func save() {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(overrides)
            try data.write(to: storeURL, options: .atomicWrite)
        } catch {
            linkerLog("OOUserLinkOverrideStore: save failed — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            overrides = try dec.decode([Override].self, from: data)
            rebuildIndex()
            // FIXED: re-save to upgrade any pre-v2 records (adds lmsTrackIDs:[])
            save()
        } catch {
            linkerLog("OOUserLinkOverrideStore: load failed — \(error)")
        }
    }
}
