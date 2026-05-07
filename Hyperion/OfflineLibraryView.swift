import SwiftUI

// MARK: - Offline Library

struct OfflineLibraryView: View {

    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var player    = PlayerViewModel.shared
    @State private var searchText: String = ""
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    private var grouped: [String: [DownloadedTrack]] {
        var dict: [String: [DownloadedTrack]] = [:]
        for track in downloads.downloadedTracks {
            let key = track.album.isEmpty ? "Unknown Album" : track.album
            dict[key, default: []].append(track)
        }
        return dict
    }

    private var filteredAlbums: [(album: String, tracks: [DownloadedTrack])] {
        grouped
            .map { (album: $0.key, tracks: $0.value) }
            .filter {
                searchNeedle.isEmpty ||
                searchNeedle.matches($0.album) ||
                $0.tracks.contains { searchNeedle.matches($0.title) || searchNeedle.matches($0.artist) }
            }
            .sorted { $0.album < $1.album }
    }

    var body: some View {
        Group {
            if downloads.downloadedTracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 52))
                        .foregroundColor(.roonTertiary)
                    Text("No Offline Music")
                        .font(.roonTitle(22))
                        .foregroundColor(.roonPrimary)
                    Text("Download albums or playlists from their detail screens to listen without a connection.")
                        .font(.roonBody(14))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredAlbums, id: \.album) { entry in
                        Section(entry.album) {
                            ForEach(entry.tracks) { track in
                                OfflineTrackRow(track: track)
                            }
                        }
                        .listRowBackground(Color.roonSurface)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Offline Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .searchable(text: $searchText, prompt: "Filter offline tracks")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
    }
}

private struct OfflineTrackRow: View {
    let track: DownloadedTrack
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var player    = PlayerViewModel.shared

    private var isActive: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(coverid: track.coverid, size: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(isActive ? .roonAccent : .roonPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if let dur = track.duration {
                Text(TimeFormatting.formatDuration(dur))
                    .font(.roonMono(11))
                    .foregroundColor(.roonTertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Build a Track from the DownloadedTrack so it can be queued.
            if let src = LibraryViewModel.shared.songs.first(where: { $0.id == track.id }) {
                player.playTracks([src])
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                downloads.removeDownload(track)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Color.roonBorder)
    }
}

// MARK: - Album detail download button

struct AlbumDownloadButton: View {
    let tracks: [Track]

    @ObservedObject private var downloads = DownloadManager.shared
    @State private var showConfirm = false

    private var allDownloaded: Bool { downloads.isAlbumDownloaded(tracks) }
    private var inProgress: Bool {
        tracks.contains { downloads.downloads[$0.id] != nil }
    }
    private var downloadedCount: Int { downloads.downloadedCount(in: tracks) }

    var body: some View {
        Button {
            if allDownloaded { return }
            if tracks.count > 5 {
                showConfirm = true
            } else {
                downloads.downloadAlbum(tracks)
                Haptics.medium()
            }
        } label: {
            Label(
                allDownloaded ? "Downloaded" : (inProgress ? "Downloading…" : "Download Album"),
                systemImage: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
            )
            .font(.roonBody(14, weight: .semibold))
            .foregroundColor(allDownloaded ? .roonAccent : .roonPrimary)
        }
        .buttonStyle(.plain)
        .disabled(allDownloaded || inProgress)
        .confirmationDialog(
            "Download \(tracks.count) tracks?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Download All") {
                downloads.downloadAlbum(tracks)
                Haptics.medium()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Playlist download button

struct PlaylistDownloadButton: View {
    let playlist: LocalPlaylist

    @ObservedObject private var downloads = DownloadManager.shared
    @State private var showConfirm = false

    private var allDownloaded: Bool { downloads.isAlbumDownloaded(playlist.tracks) }
    private var inProgress: Bool {
        playlist.tracks.contains { downloads.downloads[$0.id] != nil }
    }

    var body: some View {
        Button {
            if allDownloaded || playlist.tracks.isEmpty { return }
            showConfirm = true
        } label: {
            Label(
                allDownloaded ? "Downloaded" : "Download Offline",
                systemImage: allDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
            )
        }
        .disabled(allDownloaded || inProgress || playlist.tracks.isEmpty)
        .confirmationDialog(
            "Download \(playlist.tracks.count) tracks for offline listening?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Download") {
                downloads.downloadPlaylist(playlist)
                Haptics.medium()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
