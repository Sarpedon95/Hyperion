// StreamingFavoritesView.swift
// Hyperion — Streaming Favorites UI
// Admin only

import SwiftUI

// MARK: - Favorites root

struct StreamingFavoritesView: View {
    let source: StreamSourceType

    @State private var tracks: [StreamTrack] = []
    @State private var albums: [StreamAlbum] = []
    @State private var selectedTab = 0
    @State private var isLoading = false

    var title: String {
        switch source {
        case .qobuz:  return "Qobuz Favorites"
        case .deezer: return "Deezer Favorites"
        case .squid:  return "Squid Favorites"
        case .local:  return "Library"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Tracks").tag(0)
                Text("Albums").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedTab == 0 {
                trackList
            } else {
                albumGrid
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .refreshable { await load() }
    }

    private var trackList: some View {
        List(tracks) { track in
            StreamTrackRow(track: track)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(destination: StreamingAlbumView(album: album)) {
                        StreamAlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    private func load() async {
        isLoading = true
        async let t = loadTracks()
        async let a = loadAlbums()
        tracks = await t
        albums = await a
        isLoading = false
    }

    private func loadTracks() async -> [StreamTrack] {
        switch source {
        case .qobuz:  return await QobuzClient.shared.getUserFavorites()
        case .deezer: return await DeezerClient.shared.getUserFavorites()
        case .squid:  return await SquidClient.shared.getUserFavorites()
        case .local:  return []
        }
    }

    private func loadAlbums() async -> [StreamAlbum] {
        switch source {
        case .qobuz:  return await QobuzClient.shared.getUserFavoriteAlbums()
        case .deezer: return await DeezerClient.shared.getUserFavoriteAlbums()
        case .squid:  return await SquidClient.shared.getUserFavoriteAlbums()
        case .local:  return []
        }
    }
}

// MARK: - Album detail

struct StreamingAlbumView: View {
    let album: StreamAlbum

    @State private var tracks: [StreamTrack] = []
    @State private var isLoading = false
    @EnvironmentObject private var playerVM: PlayerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .top, spacing: 16) {
                    AsyncImage(url: album.artworkURL) { img in
                        img.resizable().aspectRatio(1, contentMode: .fit)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.2))
                    }
                    .frame(width: 120, height: 120)
                    .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title)
                            .font(.headline)
                            .lineLimit(3)
                        Text(album.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let year = album.year {
                            Text("\(year)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        SourceBadge(source: album.source)
                            .padding(.top, 4)
                    }
                }
                .padding()

                // Play All
                Button {
                    Task { await playAll() }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 12)

                Divider()

                // Tracks
                if isLoading {
                    ProgressView().padding()
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        StreamTrackRow(track: track, trackNumber: index + 1)
                            .padding(.horizontal)
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTracks() }
    }

    private func loadTracks() async {
        isLoading = true
        switch album.source {
        case .qobuz:  tracks = await QobuzClient.shared.getAlbumTracks(albumID: album.id)
        case .deezer: tracks = await DeezerClient.shared.getAlbumTracks(albumID: album.id)
        case .squid:  tracks = await SquidClient.shared.getAlbumTracks(albumID: album.id)
        case .local:  tracks = []
        }
        isLoading = false
    }

    private func playAll() async {
        guard !tracks.isEmpty else { return }
        await playerVM.playStreamTrack(tracks[0])
        for track in tracks.dropFirst() {
            await playerVM.addStreamTrackToQueue(track)
        }
    }
}

// MARK: - Track row

struct StreamTrackRow: View {
    let track: StreamTrack
    var trackNumber: Int? = nil
    @EnvironmentObject private var playerVM: PlayerViewModel

    var body: some View {
        Button {
            Task { await playerVM.playStreamTrack(track) }
        } label: {
            HStack(spacing: 12) {
                // Number or artwork
                if let num = trackNumber {
                    Text("\(num)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                } else {
                    AsyncImage(url: track.artworkURL) { img in
                        img.resizable().aspectRatio(1, contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                    }
                    .frame(width: 44, height: 44)
                    .cornerRadius(4)
                    .overlay(alignment: .topTrailing) {
                        SourceBadge(source: track.source).padding(2)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let quality = track.qualityLabel {
                    Text(quality)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Album card

struct StreamAlbumCard: View {
    let album: StreamAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: album.artworkURL) { img in
                img.resizable().aspectRatio(1, contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
            }
            .aspectRatio(1, contentMode: .fit)
            .cornerRadius(8)
            .overlay(alignment: .topTrailing) {
                SourceBadge(source: album.source).padding(6)
            }

            Text(album.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
            Text(album.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Source badge

struct SourceBadge: View {
    let source: StreamSourceType

    var label: String {
        switch source {
        case .qobuz:  return "Q"
        case .deezer: return "D"
        case .squid:  return "S"
        case .local:  return "L"
        }
    }

    var color: Color {
        switch source {
        case .qobuz:  return Color(red: 0, green: 0.706, blue: 0.847)   // #00B4D8
        case .deezer: return Color(red: 0.937, green: 0.329, blue: 0.4) // #EF5466
        case .squid:  return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .local:  return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }
}
