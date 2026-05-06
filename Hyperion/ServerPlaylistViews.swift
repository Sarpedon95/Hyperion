import SwiftUI

// MARK: - Server playlist list

struct ServerPlaylistListView: View {
    @ObservedObject private var store  = PlaylistStore.shared
    @ObservedObject private var player = PlayerViewModel.shared
    @State private var showCreateAlert = false
    @State private var newPlaylistName = ""
    @State private var showDeleteConfirm: ServerPlaylist? = nil

    var body: some View {
        List {
            if let error = store.serverPlaylistError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundColor(.roonTertiary)
                    Text(error)
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { store.syncServerPlaylists() }
                        .font(.roonBody(14, weight: .semibold))
                        .foregroundColor(.roonAccent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else if !store.isLoadingServerPlaylists && store.serverPlaylists.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 36))
                        .foregroundColor(.roonTertiary)
                    Text("No server playlists")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                    Text("Create playlists in LMS or use the + button to create one from Hyperion.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.serverPlaylists) { playlist in
                    NavigationLink {
                        ServerPlaylistDetailView(playlist: playlist)
                    } label: {
                        ServerPlaylistRowView(playlist: playlist)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.roonBorder)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            showDeleteConfirm = playlist
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .navigationTitle("Server Playlists")
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
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoadingServerPlaylists {
                    ProgressView().tint(.roonAccent)
                } else {
                    Button {
                        store.syncServerPlaylists()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .alert("New Server Playlist", isPresented: $showCreateAlert) {
            TextField("Name", text: $newPlaylistName)
                .textInputAutocapitalization(.words)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { try? await store.createServerPlaylist(name: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new playlist on the LMS server.")
        }
        .confirmationDialog(
            "Delete \"\(showDeleteConfirm?.name ?? "")\"?",
            isPresented: Binding(get: { showDeleteConfirm != nil }, set: { if !$0 { showDeleteConfirm = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete from Server", role: .destructive) {
                guard let playlist = showDeleteConfirm else { return }
                showDeleteConfirm = nil
                Task { try? await store.deleteServerPlaylist(playlist) }
            }
            Button("Cancel", role: .cancel) { showDeleteConfirm = nil }
        }
        .task {
            if store.serverPlaylists.isEmpty && !store.isLoadingServerPlaylists {
                store.syncServerPlaylists()
            }
        }
        .refreshable {
            store.syncServerPlaylists()
            // Brief wait so pull-to-refresh spinner resolves sensibly
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }
}

private struct ServerPlaylistRowView: View {
    let playlist: ServerPlaylist

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.roonElevated)
                    .frame(width: 52, height: 52)
                Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .medium))
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

// MARK: - Server playlist detail

struct ServerPlaylistDetailView: View {
    let playlist: ServerPlaylist

    @ObservedObject private var store  = PlaylistStore.shared
    @ObservedObject private var player = PlayerViewModel.shared
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var showDeleteConfirm = false
    @State private var showAddTrackError = false

    private var livePlaylist: ServerPlaylist? {
        store.serverPlaylists.first { $0.id == playlist.id }
    }

    var body: some View {
        Group {
            if let live = livePlaylist {
                List {
                    playlistHeader(live)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView().tint(.roonAccent)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else if tracks.isEmpty {
                        Text("This playlist is empty.")
                            .font(.roonBody(14))
                            .foregroundColor(.roonSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                Haptics.light()
                                player.playTracks(tracks, startingAt: index)
                            } label: {
                                SongRowView(track: track, isActive: player.currentTrack?.id == track.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Play", systemImage: "play.fill") {
                                    player.playTracks(tracks, startingAt: index)
                                }
                                Button("Add to Queue", systemImage: "text.badge.plus") {
                                    player.addTracksToQueue([track])
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.roonBorder)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .bottomOverlayAwareScroll()
                .background(Color.roonBase)
                .navigationTitle(live.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.roonBase, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button("Shuffle", systemImage: "shuffle") {
                                player.playTracks(tracks, shuffle: true)
                            }
                            .disabled(tracks.isEmpty)
                            Divider()
                            Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                showDeleteConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .confirmationDialog("Delete \"\(live.name)\"?", isPresented: $showDeleteConfirm) {
                    Button("Delete from Server", role: .destructive) {
                        Task { try? await store.deleteServerPlaylist(live) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                Text("Playlist not found")
                    .foregroundColor(.roonSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.roonBase)
            }
        }
        .task(id: playlist.id) {
            isLoading = true
            defer { isLoading = false }
            await store.fetchServerPlaylistTracks(playlist)
            tracks = store.serverPlaylists.first { $0.id == playlist.id }?.tracks ?? []
        }
    }

    private func playlistHeader(_ live: ServerPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.roonElevated)
                        .frame(width: 88, height: 88)
                    Image(systemName: "server.rack")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundColor(.roonAccent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(live.name)
                        .font(.roonTitle(26))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                    Text(live.subtitle)
                        .font(.roonBody(14))
                        .foregroundColor(.roonSecondary)
                    Text("LMS Server")
                        .font(.roonBody(11, weight: .semibold))
                        .foregroundColor(.roonTertiary)
                        .kerning(0.6)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button {
                    player.playTracks(tracks)
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
                .disabled(tracks.isEmpty)

                Button {
                    player.playTracks(tracks, shuffle: true)
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
                .disabled(tracks.isEmpty)
            }
        }
        .padding(.vertical, 14)
    }
}
