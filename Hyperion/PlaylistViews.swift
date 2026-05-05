import SwiftUI

struct AddToPlaylistSheet: View {
    let tracks: [Track]

    @ObservedObject private var store = PlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylistName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        TextField("New playlist name", text: $newPlaylistName)
                            .textInputAutocapitalization(.words)
                        Button("Create") {
                            let playlist = store.create(name: newPlaylistName)
                            store.add(tracks, to: playlist)
                            Haptics.medium()
                            dismiss()
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Create")
                } footer: {
                    Text("Adds \(tracks.count == 1 ? "this track" : "these tracks") after creating the playlist.")
                }

                Section("Existing Playlists") {
                    if store.playlists.isEmpty {
                        Text("No playlists yet")
                            .foregroundColor(.roonSecondary)
                    } else {
                        ForEach(store.playlists) { playlist in
                            Button {
                                store.add(tracks, to: playlist)
                                Haptics.light()
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(.roonAccent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .foregroundColor(.roonPrimary)
                                            .font(.roonBody(15, weight: .medium))
                                        Text(playlist.subtitle)
                                            .foregroundColor(.roonSecondary)
                                            .font(.roonBody(12))
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct PlaylistListView: View {
    @ObservedObject private var store = PlaylistStore.shared
    @State private var showCreateAlert = false
    @State private var newPlaylistName = ""

    var body: some View {
        List {
            if store.playlists.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 36))
                        .foregroundColor(.roonTertiary)
                    Text("No playlists yet")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                    Text("Create one here, or add tracks from albums, songs, queue, and Now Playing.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlistID: playlist.id)
                    } label: {
                        PlaylistRowView(playlist: playlist)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.roonBorder)
                }
                .onDelete { offsets in
                    for index in offsets {
                        guard store.playlists.indices.contains(index) else { continue }
                        store.delete(store.playlists[index])
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newPlaylistName = ""
                    showCreateAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New Playlist", isPresented: $showCreateAlert) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") { _ = store.create(name: newPlaylistName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a local Hyperion playlist.")
        }
    }
}

private struct PlaylistRowView: View {
    let playlist: LocalPlaylist

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.roonElevated)
                    .frame(width: 52, height: 52)
                Image(systemName: "music.note.list")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.roonAccent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.roonBody(16, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                Text(playlist.subtitle)
                    .font(.roonBody(13))
                    .foregroundColor(.roonSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID

    @ObservedObject private var store = PlaylistStore.shared
    @ObservedObject private var player = PlayerViewModel.shared
    @State private var showRenameAlert = false
    @State private var showDeleteConfirm = false
    @State private var renameText = ""
    @State private var grouped: [WorkGroup] = []
    @Environment(\.editMode) private var editMode

    private var playlist: LocalPlaylist? { store.playlist(id: playlistID) }

    var body: some View {
        Group {
            if let playlist {
                List {
                    playlistHeader(playlist)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    if playlist.tracks.isEmpty {
                        Text("This playlist is empty. Add tracks from albums, songs, queue, or Now Playing.")
                            .font(.roonBody(14))
                            .foregroundColor(.roonSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(grouped) { group in
                            Section {
                                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { localIndex, track in
                                    Button {
                                        if let absolute = playlist.tracks.firstIndex(where: { $0.id == track.id }) {
                                            player.playTracks(playlist.tracks, startingAt: absolute)
                                        }
                                    } label: {
                                        SongRowView(track: track, isActive: player.currentTrack?.id == track.id)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Play", systemImage: "play.fill") {
                                            if let absolute = playlist.tracks.firstIndex(where: { $0.id == track.id }) {
                                                player.playTracks(playlist.tracks, startingAt: absolute)
                                            }
                                        }
                                        Button("Add to Queue", systemImage: "text.badge.plus") {
                                            player.addTracksToQueue([track])
                                        }
                                        Button("Remove from Playlist", systemImage: "trash", role: .destructive) {
                                            if let absolute = playlist.tracks.firstIndex(where: { $0.id == track.id }) {
                                                store.remove(at: IndexSet(integer: absolute), from: playlist)
                                            }
                                        }
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparatorTint(Color.roonBorder)
                                }
                                .onDelete { offsets in
                                    let absolute = IndexSet(offsets.compactMap { offset in
                                        guard group.tracks.indices.contains(offset) else { return nil }
                                        return playlist.tracks.firstIndex(where: { $0.id == group.tracks[offset].id })
                                    })
                                    store.remove(at: absolute, from: playlist)
                                }
                                .onMove { source, destination in
                                    let absolute = IndexSet(source.compactMap { offset in
                                        guard group.tracks.indices.contains(offset) else { return nil }
                                        return playlist.tracks.firstIndex(where: { $0.id == group.tracks[offset].id })
                                    })
                                    let dest: Int
                                    if destination < group.tracks.count,
                                       let absoluteDestination = playlist.tracks.firstIndex(where: { $0.id == group.tracks[destination].id }) {
                                        dest = absoluteDestination
                                    } else if let last = group.tracks.last,
                                              let lastIndex = playlist.tracks.firstIndex(where: { $0.id == last.id }) {
                                        dest = lastIndex + 1
                                    } else {
                                        dest = playlist.tracks.count
                                    }
                                    store.move(from: absolute, to: dest, in: playlist)
                                }
                            } header: {
                                if !group.isFlatFallbackGroup || grouped.count > 1 {
                                    PlaylistWorkHeader(group: group)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .bottomOverlayAwareScroll()
                .background(Color.roonBase)
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.roonBase, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button("Rename", systemImage: "pencil") {
                                renameText = playlist.name
                                showRenameAlert = true
                            }
                            Button("Shuffle", systemImage: "shuffle") {
                                player.playTracks(playlist.tracks, shuffle: true)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .alert("Rename Playlist", isPresented: $showRenameAlert) {
                    TextField("Name", text: $renameText)
                    Button("Save") { store.rename(playlist, to: renameText) }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Delete Playlist?", isPresented: $showDeleteConfirm) {
                    Button("Delete Playlist", role: .destructive) { store.delete(playlist) }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                Text("Playlist not found")
                    .foregroundColor(.roonSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.roonBase)
            }
        }
        .task(id: playlist?.updatedAt) {
            grouped = playlist.map { LyrionAPI.shared.groupTracksByWork($0.tracks) } ?? []
        }
    }

    private func playlistHeader(_ playlist: LocalPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.roonElevated)
                        .frame(width: 88, height: 88)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundColor(.roonAccent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name)
                        .font(.roonTitle(26))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                    Text(playlist.subtitle)
                        .font(.roonBody(14))
                        .foregroundColor(.roonSecondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    player.playTracks(playlist.tracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.roonBody(15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.roonAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(playlist.tracks.isEmpty)

                Button {
                    player.playTracks(playlist.tracks, shuffle: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.roonBody(15, weight: .semibold))
                        .foregroundColor(.roonPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.roonSurface)
                        .overlay(Capsule().strokeBorder(Color.roonBorder, lineWidth: 1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(playlist.tracks.isEmpty)
            }
        }
        .padding(.vertical, 14)
    }
}

private struct PlaylistWorkHeader: View {
    let group: WorkGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.workTitle)
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.roonPrimary)
                .textCase(nil)
            if let composer = group.composer, !composer.isEmpty {
                Text(composer)
                    .font(.roonBody(11))
                    .foregroundColor(.roonSecondary)
                    .textCase(nil)
            }
        }
        .padding(.vertical, 6)
    }
}
