import SwiftUI

// MARK: - Download button (used in track row views)

struct DownloadButton: View {
    let track: Track
    @ObservedObject private var dm = DownloadManager.shared

    var body: some View {
        Group {
            if dm.isDownloaded(trackID: track.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.roonAccent)
            } else if let prog = dm.downloads[track.id] {
                switch prog.state {
                case .downloading:
                    ProgressView(value: prog.progress)
                        .progressViewStyle(.circular)
                        .tint(.roonAccent)
                        .scaleEffect(0.65)
                        .frame(width: 20, height: 20)
                case .pending:
                    ProgressView()
                        .tint(.roonAccent)
                        .scaleEffect(0.65)
                        .frame(width: 20, height: 20)
                case .failed:
                    Button { dm.download(track) } label: {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button { dm.download(track) } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.roonTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 17))
    }
}

// MARK: - Downloads list view

struct DownloadsView: View {
    @ObservedObject private var dm     = DownloadManager.shared
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        List {
            if dm.downloadedTracks.isEmpty && dm.downloads.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44))
                        .foregroundColor(.roonTertiary)
                    Text("No downloads yet")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                    Text("Download tracks from the context menu on any song row to listen offline.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
            } else {
                if !dm.downloads.isEmpty {
                    Section("In Progress") {
                        ForEach(Array(dm.downloads.keys.sorted()), id: \.self) { trackID in
                            if let prog = dm.downloads[trackID] {
                                InProgressRow(trackID: trackID, progress: prog)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparatorTint(Color.roonBorder)
                            }
                        }
                    }
                }

                if !dm.downloadedTracks.isEmpty {
                    Section("Downloaded") {
                        ForEach(dm.downloadedTracks) { downloaded in
                            Button {
                                player.playSingleTrack(dm.playableTrack(for: downloaded))
                            } label: {
                                DownloadedRow(downloaded: downloaded,
                                              isActive: player.currentTrack?.id == downloaded.id)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.roonBorder)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    dm.removeDownload(downloaded)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Play", systemImage: "play.fill") {
                                    player.playSingleTrack(dm.playableTrack(for: downloaded))
                                }
                                Button("Add to Queue", systemImage: "text.badge.plus") {
                                    player.addTracksToQueue([dm.playableTrack(for: downloaded)])
                                }
                                Divider()
                                Button("Delete Download", systemImage: "trash", role: .destructive) {
                                    dm.removeDownload(downloaded)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

// MARK: - Row subviews

private struct InProgressRow: View {
    let trackID: Int
    let progress: DownloadProgress
    @ObservedObject private var dm = DownloadManager.shared

    private var trackTitle: String {
        // Prefer the metadata captured at download start; fall back to library
        // (rarely populated cold) and finally to a numeric placeholder.
        dm.pendingTitles[trackID]
            ?? LibraryViewModel.shared.songs.first(where: { $0.id == trackID })?.title
            ?? "Track \(trackID)"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.roonElevated)
                    .frame(width: 44, height: 44)
                switch progress.state {
                case .downloading:
                    ProgressView(value: progress.progress)
                        .progressViewStyle(.circular)
                        .tint(.roonAccent)
                        .frame(width: 28)
                case .pending:
                    ProgressView().tint(.roonAccent)
                case .failed:
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.red)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(trackTitle)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                switch progress.state {
                case .downloading:
                    Text(String(format: "Downloading… %.0f%%", progress.progress * 100))
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                case .pending:
                    Text("Waiting…")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                case .failed:
                    Text("Failed")
                        .font(.roonBody(12))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            Button {
                DownloadManager.shared.cancelDownload(trackID: trackID)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.roonTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadedRow: View {
    let downloaded: DownloadedTrack
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: downloaded.coverid, size: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(downloaded.title)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(isActive ? .roonAccent : .roonPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !downloaded.artist.isEmpty {
                        Text(downloaded.artist)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                    }
                    if !downloaded.album.isEmpty {
                        Text("·")
                            .font(.roonBody(12))
                            .foregroundColor(.roonTertiary)
                        Text(downloaded.album)
                            .font(.roonBody(12))
                            .foregroundColor(.roonTertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.roonAccent)
        }
        .padding(.vertical, 6)
    }
}
