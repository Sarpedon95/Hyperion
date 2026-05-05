import Foundation

@MainActor
final class LikedTracksStore: ObservableObject {
    static let shared = LikedTracksStore()

    @Published private(set) var likedTrackIDs: Set<Int> = []
    @Published private(set) var likedTracks: [Track] = []

    private let defaultsKey = "hyperion.likedTracks.v1"
    private var saveTask: Task<Void, Never>?

    private init() {
        load()
    }

    func isLiked(_ track: Track?) -> Bool {
        guard let track else { return false }
        return likedTrackIDs.contains(track.id)
    }

    func toggle(_ track: Track) {
        isLiked(track) ? unlike(track) : like(track)
    }

    func like(_ track: Track) {
        guard likedTrackIDs.insert(track.id).inserted else { return }
        likedTracks.removeAll { $0.id == track.id }
        likedTracks.insert(track, at: 0)
        scheduleSave()
    }

    func unlike(_ track: Track) {
        unlike(trackID: track.id)
    }

    func unlike(trackID: Int) {
        guard likedTrackIDs.remove(trackID) != nil else { return }
        likedTracks.removeAll { $0.id == trackID }
        scheduleSave()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            let stored = try JSONDecoder().decode([Track].self, from: data)
            var seen = Set<Int>()
            likedTracks = stored.filter { seen.insert($0.id).inserted }
            likedTrackIDs = Set(likedTracks.map(\.id))
        } catch {
            likedTracks = []
            likedTrackIDs = []
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        if let data = try? JSONEncoder().encode(likedTracks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = likedTracks
        let key = defaultsKey
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
