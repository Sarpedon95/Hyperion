import Foundation

// Persists user corrections to OpenOpus↔LMS links in a separate file
// (oo_user_link_overrides.json) that is never overwritten by the linker.
//
// Rules:
//   confirmed — user says this IS correct; always shown first
//   rejected  — user says this is NOT correct; never shown again
//   created   — user manually created this link

@MainActor
final class OOUserLinkOverrideStore {

    static let shared = OOUserLinkOverrideStore()
    private init() { load() }

    struct Override: Codable, Identifiable {
        enum Action: String, Codable { case confirmed, rejected, created }
        let id: String          // UUID
        let openOpusWorkID: String
        let lmsAlbumID: Int
        let action: Action
        let timestamp: Date
        var note: String?
    }

    private(set) var overrides: [Override] = []

    // Quick lookup sets
    private var confirmedKeys: Set<String>  = []   // "workID:albumID"
    private var rejectedKeys:  Set<String>  = []

    // MARK: - Queries

    func isConfirmed(workID: String, albumID: Int) -> Bool {
        confirmedKeys.contains(key(workID, albumID))
    }

    func isRejected(workID: String, albumID: Int) -> Bool {
        rejectedKeys.contains(key(workID, albumID))
    }

    func action(workID: String, albumID: Int) -> Override.Action? {
        overrides.last(where: { $0.openOpusWorkID == workID && $0.lmsAlbumID == albumID })?.action
    }

    // MARK: - Mutations

    func confirm(workID: String, albumID: Int, note: String? = nil) {
        upsert(Override(
            id: UUID().uuidString,
            openOpusWorkID: workID,
            lmsAlbumID: albumID,
            action: .confirmed,
            timestamp: Date(),
            note: note
        ))
    }

    func reject(workID: String, albumID: Int, note: String? = nil) {
        upsert(Override(
            id: UUID().uuidString,
            openOpusWorkID: workID,
            lmsAlbumID: albumID,
            action: .rejected,
            timestamp: Date(),
            note: note
        ))
    }

    func create(workID: String, albumID: Int, note: String? = nil) {
        upsert(Override(
            id: UUID().uuidString,
            openOpusWorkID: workID,
            lmsAlbumID: albumID,
            action: .created,
            timestamp: Date(),
            note: note
        ))
    }

    func remove(workID: String, albumID: Int) {
        overrides.removeAll { $0.openOpusWorkID == workID && $0.lmsAlbumID == albumID }
        rebuildIndex()
        save()
    }

    // MARK: - Private

    // TODO: key is workID+albumID only. An album containing multiple works can yield
    // ambiguous overrides. Prefer workID+albumID+sortedTrackIDs once the linker
    // populates track-level IDs for all indexed candidates.
    private func key(_ workID: String, _ albumID: Int) -> String { "\(workID):\(albumID)" }

    private func upsert(_ override: Override) {
        overrides.removeAll {
            $0.openOpusWorkID == override.openOpusWorkID && $0.lmsAlbumID == override.lmsAlbumID
        }
        overrides.append(override)
        rebuildIndex()
        save()
    }

    private func rebuildIndex() {
        confirmedKeys = Set(overrides.filter { $0.action == .confirmed || $0.action == .created }
                                     .map { key($0.openOpusWorkID, $0.lmsAlbumID) })
        rejectedKeys  = Set(overrides.filter { $0.action == .rejected }
                                     .map { key($0.openOpusWorkID, $0.lmsAlbumID) })
    }

    // MARK: - Persistence

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oo_user_link_overrides.json")
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(overrides)
            try data.write(to: storeURL, options: .atomicWrite)
        } catch {
            linkerLog("OOUserLinkOverrideStore: save failed — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            overrides = try JSONDecoder().decode([Override].self, from: data)
            rebuildIndex()
        } catch {
            linkerLog("OOUserLinkOverrideStore: load failed — \(error)")
        }
    }
}
