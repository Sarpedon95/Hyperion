import SwiftUI

// MARK: - Shimmer placeholder card (shown while AI generates mixes)

struct MixShimmerCard: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(shimmerGradient)
                .frame(width: 160, height: 160)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 120, height: 13)

            RoundedRectangle(cornerRadius: 4)
                .fill(shimmerGradient)
                .frame(width: 90, height: 11)
        }
        .frame(width: 160)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.roonElevated, location: max(0, phase - 0.4)),
                .init(color: Color.roonSurface.opacity(0.7), location: phase),
                .init(color: Color.roonElevated, location: min(1, phase + 0.4))
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - AudioMuse AI mix card

struct AudiomuseMixCard: View {
    let mix: AudiomuseMix
    @ObservedObject private var player  = PlayerViewModel.shared
    @ObservedObject private var library = LibraryViewModel.shared

    private var artworkIDs: [String?] {
        mix.albumIDs.prefix(4).map { id in
            library.albums.first { $0.id == id }?.artwork_track_id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artworkGrid
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(mix.title)
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.roonPrimary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(mix.seedDescription)
                .font(.roonBody(11))
                .foregroundColor(.roonSecondary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
        .frame(width: 160)
        .onTapGesture { AudiomuseManager.shared.play(mix: mix, using: player) }
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var artworkGrid: some View {
        let ids = artworkIDs
        if ids.count >= 4 {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ArtworkView(coverid: ids[0], size: 79).clipped()
                    ArtworkView(coverid: ids[1], size: 79).clipped()
                }
                GridRow {
                    ArtworkView(coverid: ids[2], size: 79).clipped()
                    ArtworkView(coverid: ids[3], size: 79).clipped()
                }
            }
        } else {
            ArtworkView(coverid: ids.first ?? nil, size: 160)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button { AudiomuseManager.shared.play(mix: mix, using: player) } label: {
            Label("Play Now", systemImage: "play.fill")
        }
        Button {
            let songs = library.songs
            let tracks = mix.trackIDs.compactMap { id in songs.first(where: { $0.id == id }) }
            guard !tracks.isEmpty else { return }
            player.playNext(tracks.shuffled())
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            let songs = library.songs
            let tracks = mix.trackIDs.compactMap { id in songs.first(where: { $0.id == id }) }
            guard !tracks.isEmpty else { return }
            player.addTracksToQueue(tracks.shuffled())
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }
    }
}

// MARK: - Mix card (160×200pt, 2×2 artwork grid)

struct MixCard: View {
    let mix: LocalMix
    @ObservedObject private var player  = PlayerViewModel.shared
    @ObservedObject private var library = LibraryViewModel.shared

    private var artworkIDs: [String?] {
        mix.albumIDs.prefix(4).map { id in
            library.albums.first { $0.id == id }?.artwork_track_id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artworkGrid
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(mix.title)
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.roonPrimary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            Text(mix.subtitle)
                .font(.roonBody(11))
                .foregroundColor(.roonSecondary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
        .frame(width: 160)
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var artworkGrid: some View {
        let ids = artworkIDs
        if ids.count >= 4 {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ArtworkView(coverid: ids[0], size: 79).clipped()
                    ArtworkView(coverid: ids[1], size: 79).clipped()
                }
                GridRow {
                    ArtworkView(coverid: ids[2], size: 79).clipped()
                    ArtworkView(coverid: ids[3], size: 79).clipped()
                }
            }
        } else {
            ArtworkView(coverid: ids.first ?? nil, size: 160)
        }
    }

    private func tracksForMix() -> [Track] {
        let albumSet = Set(mix.albumIDs)
        return library.songs.filter { albumSet.contains($0.albumID ?? -1) }.shuffled()
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            MixGenerator.shared.play(mix: mix, using: player)
        } label: {
            Label("Play Now", systemImage: "play.fill")
        }

        Button {
            let tracks = tracksForMix()
            guard !tracks.isEmpty else { return }
            player.playNext(tracks)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            let tracks = tracksForMix()
            guard !tracks.isEmpty else { return }
            player.addTracksToQueue(tracks)
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }
    }
}
