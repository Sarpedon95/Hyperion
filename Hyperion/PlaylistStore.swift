import Foundation
import SwiftUI

// MARK: - Server playlist model (read-write against LMS)

struct ServerPlaylist: Identifiable, Hashable {
    let id: String          // LMS numeric ID stored as String for safety
    let name: String
    var tracks: [Track]
    var trackCount: Int

    var subtitle: String {
        let n = tracks.isEmpty ? trackCount : tracks.count
        return n == 1 ? "1 track" : "\(n) tracks"
    }
}

// MARK: - Local playlist model

struct LocalPlaylist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tracks: [Track]
    var createdAt: Date
    var updatedAt: Date
    var serverPlaylistID: String? = nil

    var subtitle: String {
        let count = tracks.count
        return count == 1 ? "1 track" : "\(count) tracks"
    }
}

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    // MARK: - Local playlists
    @Published private(set) var playlists: [LocalPlaylist] = []

    private let filename  = "hyperion_playlists.json"
    private let legacyKey = "hyperion.localPlaylists.v1"
    private var saveTask: Task<Void, Never>?

    // MARK: - Server playlists
    @Published private(set) var serverPlaylists: [ServerPlaylist] = []
    @Published private(set) var isLoadingServerPlaylists: Bool = false
    @Published var serverPlaylistError: String? = nil
    private var serverSyncTask: Task<Void, Never>? = nil

    private init() {
        load()
    }

    @discardableResult
    func create(name: String) -> LocalPlaylist {
        let trimmed = sanitizedName(name, fallback: "New Playlist")
        let playlist = LocalPlaylist(id: UUID(), name: uniqueName(trimmed), tracks: [], createdAt: Date(), updatedAt: Date())
        playlists.insert(playlist, at: 0)
        scheduleSave()
        return playlist
    }

    func rename(_ playlist: LocalPlaylist, to name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].name = uniqueName(sanitizedName(name, fallback: playlist.name), excluding: playlist.id)
        playlists[idx].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ playlist: LocalPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        scheduleSave()
    }

    func add(_ tracks: [Track], to playlist: LocalPlaylist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        var existing = Set(playlists[idx].tracks.map(\.id))
        let additions = tracks.filter { existing.insert($0.id).inserted }
        guard !additions.isEmpty else { return }
        playlists[idx].tracks.append(contentsOf: additions)
        playlists[idx].updatedAt = Date()
        scheduleSave()
    }

    func remove(at offsets: IndexSet, from playlist: LocalPlaylist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].tracks.remove(atOffsets: offsets)
        playlists[idx].updatedAt = Date()
        scheduleSave()
    }

    func move(from source: IndexSet, to destination: Int, in playlist: LocalPlaylist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].tracks.move(fromOffsets: source, toOffset: destination)
        playlists[idx].updatedAt = Date()
        scheduleSave()
    }

    func playlist(id: UUID) -> LocalPlaylist? {
        playlists.first { $0.id == id }
    }

    @discardableResult
    func saveQueueAsPlaylist(_ tracks: [Track], suggestedName: String = "Queue") -> LocalPlaylist? {
        guard !tracks.isEmpty else { return nil }
        var playlist = create(name: suggestedName)
        add(tracks, to: playlist)
        playlist = playlists.first(where: { $0.id == playlist.id }) ?? playlist
        return playlist
    }

    private func load() {
        let fileURL = AppFiles.url(for: filename)
        // One-time migration from UserDefaults
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let data = UserDefaults.standard.data(forKey: legacyKey) {
            try? data.write(to: fileURL, options: .atomicWrite)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            playlists = try JSONDecoder().decode([LocalPlaylist].self, from: data)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            playlists = []
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let url = AppFiles.url(for: filename)
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: url, options: .atomicWrite)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = playlists
        let url = AppFiles.url(for: filename)
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomicWrite)
            }
        }
    }

    // MARK: - Server playlist operations

    func syncServerPlaylists() {
        serverSyncTask?.cancel()
        serverSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoadingServerPlaylists = true
            self.serverPlaylistError = nil
            defer { self.isLoadingServerPlaylists = false }
            do {
                self.serverPlaylists = try await LyrionAPI.shared.getLMSPlaylists()
            } catch is CancellationError {
                // Cancelled — leave current list intact
            } catch {
                self.serverPlaylistError = error.localizedDescription
            }
        }
    }

    func fetchServerPlaylistTracks(_ playlist: ServerPlaylist) async {
        guard let idx = serverPlaylists.firstIndex(where: { $0.id == playlist.id }) else { return }
        do {
            let tracks = try await LyrionAPI.shared.getLMSPlaylistTracks(playlistID: playlist.id)
            serverPlaylists[idx].tracks = tracks
            serverPlaylists[idx].trackCount = tracks.count
        } catch {
            // Silently ignore — the existing (possibly empty) list is still shown
        }
    }

    @discardableResult
    func createServerPlaylist(name: String) async throws -> ServerPlaylist {
        let created = try await LyrionAPI.shared.createLMSPlaylist(name: name)
        serverPlaylists.insert(created, at: 0)
        return created
    }

    func addToServerPlaylist(_ playlist: ServerPlaylist, tracks: [Track]) async throws {
        try await LyrionAPI.shared.addTracksToLMSPlaylist(
            playlistID: playlist.id,
            trackIDs: tracks.map(\.id)
        )
        if let idx = serverPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            serverPlaylists[idx].trackCount += tracks.count
        }
    }

    func deleteServerPlaylist(_ playlist: ServerPlaylist) async throws {
        try await LyrionAPI.shared.deleteLMSPlaylist(playlistID: playlist.id)
        serverPlaylists.removeAll { $0.id == playlist.id }
    }

    // MARK: - Sync local playlist to LMS server

    func syncToServer(_ playlist: LocalPlaylist) async throws {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if let serverID = playlist.serverPlaylistID {
            // Playlist already synced — add any new tracks
            try await LyrionAPI.shared.addTracksToLMSPlaylist(
                playlistID: serverID,
                trackIDs: playlist.tracks.map(\.id)
            )
        } else {
            // Create new server playlist then populate it
            let server = try await LyrionAPI.shared.createLMSPlaylist(name: playlist.name)
            if !playlist.tracks.isEmpty {
                try await LyrionAPI.shared.addTracksToLMSPlaylist(
                    playlistID: server.id,
                    trackIDs: playlist.tracks.map(\.id)
                )
            }
            playlists[idx].serverPlaylistID = server.id
            playlists[idx].updatedAt = Date()
            scheduleSave()
        }
    }

    // MARK: - Local playlist helpers

    private func sanitizedName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func uniqueName(_ base: String, excluding id: UUID? = nil) -> String {
        let existing = Set(playlists.filter { $0.id != id }.map { SearchTextNormalizer.folded($0.name) })
        if !existing.contains(SearchTextNormalizer.folded(base)) { return base }
        var n = 2
        while existing.contains(SearchTextNormalizer.folded("\(base) \(n)")) { n += 1 }
        return "\(base) \(n)"
    }
}
