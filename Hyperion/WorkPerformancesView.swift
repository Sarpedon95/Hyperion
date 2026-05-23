import SwiftUI

// MARK: - Work performances
//
// Shows every recording of a single work in the library, grouped by
// (album_id, WORKID slug). When two performances of the same work live
// on one album (a Karajan re-issue, for example) the slug is what tells
// them apart — it's rendered as a small grey badge on the card.
//
// Tapping a performance pushes AlbumDetailView and scrolls to the first
// track of that performance.

struct WorkPerformancesView: View {

    let workID: Int
    let workTitle: String
    /// Optional pre-loaded tracks. When supplied (e.g. by a caller that
    /// already fetched movements) the view skips the initial fetch.
    var initialTracks: [Track] = []

    @State private var performances: [Performance] = []
    @State private var isLoading: Bool = true
    @State private var didLoadOnce: Bool = false
    @State private var albumNavRequest: AlbumNavRequest? = nil

    @ObservedObject private var library = LibraryViewModel.shared

    var body: some View {
        Group {
            if isLoading && performances.isEmpty {
                ProgressView().tint(.roonAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if performances.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No performances of this work were found in the library.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                performanceList
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(workTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $albumNavRequest) { req in
            AlbumDetailView(
                album: req.album,
                scrollToTrackID: req.firstTrackID,
                autoPlay: req.autoPlay
            )
        }
        .task { await loadIfNeeded() }
    }

    // MARK: - List

    private var performanceList: some View {
        List {
            ForEach(performances) { performance in
                Button {
                    albumNavRequest = AlbumNavRequest(
                        album:        performance.album,
                        firstTrackID: performance.firstTrackID,
                        autoPlay:     false
                    )
                } label: {
                    PerformanceCard(performance: performance)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.roonSurface)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        guard !didLoadOnce else { return }
        isLoading = true
        let tracks: [Track] = initialTracks.isEmpty
            ? await LyrionAPI.shared.fetchTracksForWork(workID: workID)
            : initialTracks

        performances = await Self.buildPerformances(from: tracks, library: library)
        isLoading = false
        didLoadOnce = true
    }

    /// Groups tracks into performances by `(albumID, WORKID slug)` and
    /// resolves each performance's classical metadata for the card header.
    static func buildPerformances(
        from tracks: [Track],
        library: LibraryViewModel
    ) async -> [Performance] {
        guard !tracks.isEmpty else { return [] }

        // Resolve metadata for every track so we know its WORKID slug. The
        // resolver caches across the session, so repeat visits are free.
        var metadataByID: [Int: ClassicalMetadata?] = [:]
        for track in tracks where metadataByID[track.id] == nil {
            metadataByID[track.id] = await ClassicalMetadataResolver.shared.resolve(trackID: track.id)
        }

        struct Key: Hashable { let albumID: Int; let slug: String? }
        var groups: [Key: [Track]] = [:]
        var order: [Key] = []
        for track in tracks {
            let albumID = track.albumID ?? 0
            let slug = metadataByID[track.id].flatMap { $0?.workID_slug }
            let key = Key(albumID: albumID, slug: slug)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }

        let albumIndex = Dictionary(uniqueKeysWithValues: library.albums.map { ($0.id, $0) })

        return order.compactMap { key -> Performance? in
            let groupTracks = (groups[key] ?? []).sorted { lhs, rhs in
                let ld = lhs.discnum ?? 0, rd = rhs.discnum ?? 0
                if ld != rd { return ld < rd }
                return (lhs.tracknum ?? 0) < (rhs.tracknum ?? 0)
            }
            guard let first = groupTracks.first else { return nil }
            let metadata = metadataByID[first.id]?.flatMap { $0 }
            let album = albumIndex[key.albumID]
                ?? Album(
                    id:               key.albumID,
                    album:            first.album ?? "Unknown Album",
                    artist:           first.albumartist ?? first.trackartist,
                    year:             metadata?.recordingYear ?? first.year,
                    artwork_track_id: first.coverid,
                    composer:         metadata?.composer ?? first.composer,
                    isClassical:      first.isClassical
                )

            return Performance(
                id: "\(key.albumID)|\(key.slug ?? "")",
                album: album,
                conductor: metadata?.conductor,
                ensemble: metadata?.ensemble,
                recordingYear: metadata?.recordingYear ?? first.year,
                workIDSlug: key.slug,
                tracks: groupTracks,
                firstTrackID: groupTracks.first?.id
            )
        }
    }

    // MARK: - Performance model

    struct Performance: Identifiable {
        let id: String
        let album: Album
        let conductor: String?
        let ensemble: String?
        let recordingYear: Int?
        let workIDSlug: String?
        let tracks: [Track]
        let firstTrackID: Int?

        var performerLine: String? {
            switch (conductor?.isEmpty == false ? conductor : nil,
                    ensemble?.isEmpty  == false ? ensemble  : nil) {
            case let (c?, e?): return "\(c) · \(e)"
            case let (c?, nil): return c
            case let (nil, e?): return e
            default: return nil
            }
        }
    }
}

// MARK: - Card

private struct PerformanceCard: View {
    let performance: WorkPerformancesView.Performance

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: performance.album.artwork_track_id, size: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                if let performer = performance.performerLine {
                    Text(performer)
                        .font(.roonBody(14, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                } else {
                    Text(performance.album.album)
                        .font(.roonBody(14, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let year = performance.recordingYear, year > 0 {
                        Text(String(year))
                            .font(.roonMono(12))
                            .foregroundColor(.roonTertiary)
                    }
                    if performance.recordingYear != nil && performance.tracks.count > 0 {
                        Text("·")
                            .font(.roonBody(12))
                            .foregroundColor(.roonTertiary)
                    }
                    if performance.tracks.count > 0 {
                        Text("\(performance.tracks.count) movement\(performance.tracks.count == 1 ? "" : "s")")
                            .font(.roonBody(12))
                            .foregroundColor(.roonTertiary)
                    }
                }

                if let slug = performance.workIDSlug, !slug.isEmpty {
                    Text(slug)
                        .font(.roonMono(11))
                        .foregroundColor(.roonTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(.vertical, 4)
    }
}
