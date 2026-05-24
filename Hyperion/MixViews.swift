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

    /// Coverids resolved for `mix.albumIDs`. Seeded from the in-memory album
    /// cache and topped up with a server fetch when entries are missing, so
    /// the artwork grid still renders cold (before Albums tab pagination).
    @State private var resolvedCoverIDs: [String?] = []

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
        .onTapGesture { Task { await AudiomuseManager.shared.play(mix: mix, using: player) } }
        .contextMenu { contextMenuItems }
        .task(id: mix.id) { await resolveArtworkIfNeeded() }
    }

    @ViewBuilder
    private var artworkGrid: some View {
        let ids = resolvedCoverIDs.isEmpty ? localArtworkIDs : resolvedCoverIDs
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

    /// Initial best-effort lookup from the in-memory album cache.
    private var localArtworkIDs: [String?] {
        mix.albumIDs.prefix(4).map { id in
            library.albums.first { $0.id == id }?.artwork_track_id
        }
    }

    /// Resolve any missing coverids via a server fetch. No-op when the local
    /// cache already covers every requested album ID.
    private func resolveArtworkIfNeeded() async {
        let local = localArtworkIDs
        guard local.contains(where: { $0 == nil }) else {
            resolvedCoverIDs = local
            return
        }
        let ids = Array(mix.albumIDs.prefix(4))
        guard let albums = try? await LyrionAPI.shared.getAlbumsByIDs(ids, count: ids.count) else { return }
        let lookup = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.artwork_track_id) })
        resolvedCoverIDs = ids.map { lookup[$0] ?? nil }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            Task { await AudiomuseManager.shared.play(mix: mix, using: player) }
        } label: {
            Label("Play Now", systemImage: "play.fill")
        }
        Button {
            Task {
                let tracks = await AudiomuseManager.shared.resolvedTracks(for: mix)
                guard !tracks.isEmpty else {
                    Haptics.warning()
                    player.error = "Couldn't load tracks for \(mix.title)."
                    return
                }
                player.playNext(tracks.shuffled())
            }
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            Task {
                let tracks = await AudiomuseManager.shared.resolvedTracks(for: mix)
                guard !tracks.isEmpty else {
                    Haptics.warning()
                    player.error = "Couldn't load tracks for \(mix.title)."
                    return
                }
                player.addTracksToQueue(tracks.shuffled())
            }
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
