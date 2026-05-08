import SwiftUI
import UIKit

struct QueueView: View {

    @Binding var path: NavigationPath

    init(path: Binding<NavigationPath> = .constant(NavigationPath())) {
        _path = path
    }

    @ObservedObject private var player = PlayerViewModel.shared
    @ObservedObject private var playlists = PlaylistStore.shared
    @State private var showingClearConfirm: Bool = false
    @State private var showingSaveQueueAlert: Bool = false
    @State private var queuePlaylistName: String = ""

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Color.roonBase.ignoresSafeArea())
                .navigationTitle("Queue")
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(Color.roonBase, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    if !player.queue.isEmpty {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Menu {
                                Button("Save Queue as Playlist", systemImage: "music.note.list") {
                                    queuePlaylistName = "Queue"
                                    showingSaveQueueAlert = true
                                }
                                Button("Clear Queue", systemImage: "trash", role: .destructive) {
                                    showingClearConfirm = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
                .confirmationDialog("Clear Queue", isPresented: $showingClearConfirm) {
                    Button("Clear Queue", role: .destructive) {
                        Haptics.medium()
                        player.clearQueue()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Save Queue as Playlist", isPresented: $showingSaveQueueAlert) {
                    TextField("Name", text: $queuePlaylistName)
                    Button("Save") {
                        let name = queuePlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Queue" : queuePlaylistName
                        _ = playlists.saveQueueAsPlaylist(player.queue, suggestedName: name)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Creates a local playlist from the current queue order.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if player.queue.isEmpty {
            EmptyQueueView()
        } else {
            ScrollViewReader { proxy in
                List {
                    if let current = player.currentTrack {
                        Section {
                            NowPlayingQueueRow(track: current)
                                .id(player.currentIndex)
                        } header: {
                            RoonListHeader("NOW PLAYING")
                        }
                        .listRowBackground(Color.roonSurface)
                        .listSectionSeparator(.hidden)
                    }

                    Section {
                        ForEach(player.upcomingWorkGroups) { group in
                            WorkQueueGroupView(group: group, currentIndex: player.currentIndex)
                        }
                        // POLISH: drag-to-reorder work groups in the queue.
                        // moveInQueue operates on absolute track indices, so we
                        // translate the work-group-level move into a track-index
                        // range so entire works move together as a unit.
                        .onMove { source, destination in
                            let groups = player.upcomingWorkGroups
                            var trackSource = IndexSet()
                            for groupIndex in source {
                                guard groupIndex < groups.count else { continue }
                                for item in groups[groupIndex].tracks {
                                    trackSource.insert(item.index)
                                }
                            }
                            let destGroupIndex = min(destination, groups.count)
                            let destTrackIndex: Int
                            if destGroupIndex < groups.count {
                                destTrackIndex = groups[destGroupIndex].tracks.first?.index ?? player.queue.count
                            } else {
                                destTrackIndex = player.queue.count
                            }
                            Haptics.light()
                            player.moveInQueue(from: trackSource, to: destTrackIndex)
                        }
                        .contentShape(Rectangle())
                    } header: {
                        RoonListHeader("UP NEXT")
                    }
                    .listRowBackground(Color.clear)
                    .listSectionSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
                .onAppear {
                    withAnimation { proxy.scrollTo(player.currentIndex, anchor: .center) }
                }
                .onChange(of: player.currentIndex) { _, newIndex in
                    withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Section header

struct RoonListHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.roonBody(11, weight: .semibold))
            .foregroundColor(.roonAccent)
            .kerning(1.4)
    }
}

// MARK: - Now Playing row

struct NowPlayingQueueRow: View {
    let track: Track
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: track.coverid, size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                Text(track.composer ?? track.albumartist ?? "")
                    .font(.roonBody(13))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Group {
                if #available(iOS 17.0, *) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                } else {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.circle")
                }
            }
            .font(.system(size: 16))
            .foregroundColor(.roonAccent)
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Work group in queue

struct WorkQueueGroupView: View {
    let group: QueueWorkGroup
    let currentIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.workTitle)
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                if let composer = group.composer, !composer.isEmpty {
                    Text(composer)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ForEach(group.tracks, id: \.index) { item in
                QueueTrackRow(
                    track:      item.track,
                    queueIndex: item.index,
                    isUpcoming: item.index > currentIndex
                )
                .id(item.index)

                if item.index != group.tracks.last?.index {
                    Color.roonBorder.frame(height: 0.5).opacity(0.5).padding(.leading, 52)
                }
            }
        }
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Individual queue track row

struct QueueTrackRow: View {

    let track: Track
    let queueIndex: Int
    let isUpcoming: Bool
    @ObservedObject private var player = PlayerViewModel.shared
    @State private var showingAddToPlaylist = false
    @State private var navigateToAlbum: Album? = nil
    @State private var navigateToArtist: Artist? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text("\(queueIndex + 1)")
                .font(.roonMono(12))
                .foregroundColor(.roonTertiary)
                .frame(width: 24)

            Text(track.title)
                .font(.roonBody(14, weight: isUpcoming ? .regular : .medium))
                .foregroundColor(isUpcoming ? .roonSecondary : .roonPrimary)
                .lineLimit(2)

            Spacer()

            // BUG FIX: Use Track.durationFormatted (already handles H:MM:SS) instead
            // of duplicating the formatting logic here.
            Text(track.durationFormatted)
                .font(.roonMono(12))
                .foregroundColor(.roonTertiary)

            Button {
                Haptics.light()
                player.playTrack(at: queueIndex)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.roonTertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play \(track.title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        // PASS 6 — BUG FIX: the original used `.swipeActions(...)` here, but
        // SwiftUI only fires swipeActions on the top-level row of a List, and
        // QueueTrackRow is nested inside WorkQueueGroupView's VStack. The
        // swipe gesture was silently swallowed. `.contextMenu` works at any
        // depth (long-press to invoke) and is the canonical iOS pattern for
        // per-item destructive actions in a grouped list.
        .contextMenu {
            Button {
                Haptics.light()
                player.playTrack(at: queueIndex)
            } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button {
                Haptics.light()
                player.playNext([track])
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button(role: .destructive) {
                Haptics.medium()
                player.removeFromQueue(at: queueIndex)
            } label: {
                Label("Remove from Queue", systemImage: "trash")
            }
            Button {
                if let albumID = track.albumID,
                   let album = LibraryViewModel.shared.albums.first(where: { $0.id == albumID }) {
                    navigateToAlbum = album
                }
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
            Button {
                let name = track.trackartist ?? track.albumartist ?? ""
                guard !name.isEmpty else { return }
                navigateToArtist = LibraryViewModel.shared.artists.first { $0.name == name }
                    ?? Artist(id: 0, name: name)
            } label: {
                Label("Go to Artist", systemImage: "person.crop.circle")
            }
            Button {
                showingAddToPlaylist = true
            } label: {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddToPlaylistSheet(tracks: [track])
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .sheet(item: $navigateToAlbum) { album in
            NavigationStack { AlbumDetailView(album: album) }
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .sheet(item: $navigateToArtist) { artist in
            NavigationStack { ArtistDetailView(artist: artist) }
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .accessibilityAction(named: "Remove from queue") {
            player.removeFromQueue(at: queueIndex)
        }
    }
}

// MARK: - Empty state

struct EmptyQueueView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.below.rectangle")
                .font(.system(size: 52))
                .foregroundColor(.roonTertiary)
            Text("Queue is empty")
                .font(.roonTitle(20))
                .foregroundColor(.roonPrimary)
            Text("Browse your library and add works to start listening")
                .font(.roonBody(15))
                .foregroundColor(.roonSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
