import SwiftUI

// OpenOpus work detail — separate from the LMS WorkDetailView in LibraryView.swift.

struct OOWorkDetailView: View {

    let work: OOWork
    let composer: OOComposer

    @StateObject private var vm: OOWorkDetailViewModel
    @ObservedObject  private var player  = PlayerViewModel.shared
    @ObservedObject  private var linker  = LMSLibraryLinker.shared

    init(work: OOWork, composer: OOComposer) {
        self.work = work
        self.composer = composer
        _vm = StateObject(wrappedValue: OOWorkDetailViewModel(workID: work.id))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.bottom, 4)

                if let detail = vm.detail {
                    metaBadges(detail: detail)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                    Divider().background(Color.roonBorder)
                }

                recordingsSection
                    .padding(.vertical, 16)

                if let detail = vm.detail, let performers = detail.performers, !performers.isEmpty {
                    Divider().background(Color.roonBorder)
                    performersSection(performers: performers)
                        .padding(.vertical, 16)
                }

                if vm.isLoading {
                    ProgressView().tint(.roonAccent).padding(40)
                }

                Spacer(minLength: 60)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(work.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await vm.load() }
        .task(id: work.id) { await vm.searchLibrary(work: work, composer: composer) }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Color.roonElevated
            if let url = composerPortraitURL {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.roonElevated }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipped()
                .overlay(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.3),
                            .init(color: Color.roonBase.opacity(0.92), location: 1.0)
                        ]),
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(work.title)
                    .font(.roonTitle(20))
                    .foregroundColor(.roonPrimary)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                Text(composer.complete_name)
                    .font(.roonBody(14))
                    .foregroundColor(.roonSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(height: composerPortraitURL != nil ? 180 : 120)
    }

    // MARK: - Meta badges

    private func metaBadges(detail: OOWorkDetailResponse) -> some View {
        HStack(spacing: 8) {
            if let genre = work.genre, !genre.isEmpty {
                OOBadge(text: genre, color: .roonAccent)
            }
            if let epoch = composer.epoch, !epoch.isEmpty {
                OOBadge(text: epoch, color: epochColor(epoch))
            }
            if work.isPopular {
                OOBadge(text: "★ Popular", color: Color(hex: "#d4a042"))
            }
            Spacer()
        }
    }

    // MARK: - Recordings section

    @ViewBuilder
    private var recordingsSection: some View {
        let indexed  = linker.candidates(forWorkID: work.id)
        let isFallback = indexed.isEmpty
        let display  = isFallback ? vm.fallbackCandidates : indexed

        VStack(alignment: .leading, spacing: 10) {
            // Section header changes to signal data source
            HStack(spacing: 6) {
                Text("IN YOUR LIBRARY")
                    .font(.roonBody(11, weight: .semibold))
                    .foregroundColor(.roonAccent)
                    .kerning(1.2)
                if isFallback && !display.isEmpty {
                    Text("QUICK SEARCH")
                        .font(.roonBody(9, weight: .semibold))
                        .foregroundColor(.roonTertiary)
                        .kerning(0.8)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.roonElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            if vm.isSearchingLibrary {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8).tint(.roonAccent)
                    Text("Searching library…")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                }
                .padding(.horizontal, 16)
            } else if display.isEmpty {
                Text("Not found in your library")
                    .font(.roonBody(13))
                    .foregroundColor(.roonTertiary)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(display.prefix(5).enumerated()), id: \.element.id) { idx, candidate in
                        RecordingCandidateRow(candidate: candidate, workID: work.id)
                        if idx < min(display.count, 5) - 1 {
                            Divider().background(Color.roonBorder).padding(.leading, 82)
                        }
                    }
                }
                .background(Color.roonSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Performers

    private func performersSection(performers: [OOPerformer]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PERFORMERS")
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(.roonAccent)
                .kerning(1.2)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(Array(performers.enumerated()), id: \.element.id) { idx, performer in
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.roonElevated)
                                .frame(width: 38, height: 38)
                            if let url = performer.portrait.flatMap(URL.init) {
                                AsyncImage(url: url) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: { Color.clear }
                                .frame(width: 38, height: 38)
                                .clipShape(Circle())
                            } else {
                                Text(NameFormatting.initials(performer.name))
                                    .font(.roonTitle(12))
                                    .foregroundColor(.roonAccent)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(performer.name)
                                .font(.roonBody(14, weight: .medium))
                                .foregroundColor(.roonPrimary)
                                .lineLimit(1)
                            if let role = performer.role ?? LMSLibraryLinker.shared.role(for: performer.name),
                               !role.isEmpty {
                                Text(role)
                                    .font(.roonBody(11))
                                    .foregroundColor(.roonTertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if idx < performers.count - 1 {
                        Divider().background(Color.roonBorder).padding(.leading, 68)
                    }
                }
            }
            .background(Color.roonSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
        }
    }

    private var composerPortraitURL: URL? {
        guard let p = composer.portrait, !p.isEmpty else { return nil }
        return URL(string: p)
    }
}

// MARK: - Recording candidate row

struct RecordingCandidateRow: View {

    let candidate: WorkRecordingCandidate
    let workID: String
    @ObservedObject private var player  = PlayerViewModel.shared
    @ObservedObject private var linker  = LMSLibraryLinker.shared
    private let overrides = OOUserLinkOverrideStore.shared

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(coverid: candidate.artworkTrackID, size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.lmsAlbumName)
                        .font(.roonBody(14, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(1)
                    sourceLabel
                }

                if let summary = candidate.performerSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if candidate.trackCount > 0 {
                        Text("\(candidate.trackCount) tracks")
                            .font(.roonBody(11))
                            .foregroundColor(.roonTertiary)
                    }
                    confidenceDot
                    Text(candidate.matchReason)
                        .font(.roonBody(10))
                        .foregroundColor(.roonTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button { playCandidate() } label: {
                Image(systemName: isConfirmed ? "checkmark.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(isConfirmed ? .green : .roonAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { contextMenuItems }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var sourceLabel: some View {
        if isConfirmed {
            Text("CONFIRMED")
                .font(.roonBody(8, weight: .semibold))
                .foregroundColor(.green)
                .kerning(0.5)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else if candidate.source == .fallback {
            Text("QUICK SEARCH")
                .font(.roonBody(8, weight: .semibold))
                .foregroundColor(.roonTertiary)
                .kerning(0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.roonElevated)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Text("INDEXED")
                .font(.roonBody(8, weight: .semibold))
                .foregroundColor(.roonAccent)
                .kerning(0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.roonAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private var confidenceDot: some View {
        Circle()
            .fill(confidenceColor)
            .frame(width: 6, height: 6)
    }

    private var confidenceColor: Color {
        if isConfirmed { return .green }
        switch candidate.confidence {
        case 0.75...: return .green
        case 0.50...: return .yellow
        default:      return .orange
        }
    }

    private var isConfirmed: Bool {
        overrides.isConfirmed(workID: workID, albumID: candidate.lmsAlbumID)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if isConfirmed {
            Button(role: .destructive) {
                overrides.remove(workID: workID, albumID: candidate.lmsAlbumID)
                linker.objectWillChange.send()
            } label: {
                Label("Remove confirmation", systemImage: "xmark.circle")
            }
        } else {
            Button {
                linker.confirmCandidate(workID: workID, albumID: candidate.lmsAlbumID)
            } label: {
                Label("Confirm this match", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                linker.rejectCandidate(workID: workID, albumID: candidate.lmsAlbumID)
            } label: {
                Label("Not a match", systemImage: "hand.thumbsdown")
            }
        }
    }

    // MARK: - Play

    private func playCandidate() {
        Task {
            do {
                let allTracks = try await LyrionAPI.shared.getTracksForAlbum(albumID: candidate.lmsAlbumID)
                guard !allTracks.isEmpty else { return }

                let tracksToPlay: [Track]
                if !candidate.lmsTrackIDs.isEmpty {
                    let trackByID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
                    let missing = candidate.lmsTrackIDs.filter { trackByID[$0] == nil }
                    if !missing.isEmpty {
                        linkerLog("RecordingCandidateRow: \(missing.count)/\(candidate.lmsTrackIDs.count) indexed track IDs not found in album \(candidate.lmsAlbumID): \(missing)")
                    }
                    let ordered = candidate.lmsTrackIDs.compactMap { trackByID[$0] }
                    if ordered.isEmpty {
                        linkerLog("RecordingCandidateRow: all indexed track IDs missing from album \(candidate.lmsAlbumID); falling back to full album")
                        tracksToPlay = allTracks
                    } else {
                        tracksToPlay = ordered
                    }
                } else {
                    tracksToPlay = allTracks
                }

                let groups = LyrionAPI.shared.groupTracksByWork(tracksToPlay)
                if groups.isEmpty {
                    player.playSingleTrack(tracksToPlay[0])
                } else {
                    player.playAlbum(groups)
                }
            } catch {
                linkerLog("RecordingCandidateRow: play failed for album \(candidate.lmsAlbumID): \(error)")
            }
        }
    }
}

// MARK: - Badge

struct OOBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.roonBody(11, weight: .semibold))
            .foregroundColor(color)
            .kerning(0.4)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - ViewModel

@MainActor
final class OOWorkDetailViewModel: ObservableObject {

    @Published var detail: OOWorkDetailResponse? = nil
    @Published var isLoading: Bool = false
    @Published var isSearchingLibrary: Bool = false
    // Fallback candidates from live fuzzy search (shown when linker has no stored data)
    @Published var fallbackCandidates: [WorkRecordingCandidate] = []

    private let workID: String

    init(workID: String) { self.workID = workID }

    func load() async {
        guard detail == nil else { return }
        isLoading = true
        do {
            detail = try await OpenOpusService.shared.workDetail(workID)
        } catch {
            linkerLog("OOWorkDetailViewModel.load failed for workID \(workID): \(error)")
        }
        isLoading = false
    }

    func searchLibrary(work: OOWork, composer: OOComposer) async {
        guard LMSLibraryLinker.shared.candidates(forWorkID: work.id).isEmpty else { return }
        isSearchingLibrary = true
        fallbackCandidates = []
        let term = "\(composer.complete_name) \(work.title)"
        do {
            let albums = try await LyrionAPI.shared.searchAlbums(term: term, count: 20)
            fallbackCandidates = buildFallbackCandidates(albums: albums, work: work, composer: composer)
        } catch {
            linkerLog("OOWorkDetailViewModel.searchLibrary failed: \(error)")
        }
        isSearchingLibrary = false
    }

    private func buildFallbackCandidates(
        albums: [Album],
        work: OOWork,
        composer: OOComposer
    ) -> [WorkRecordingCandidate] {
        var results: [WorkRecordingCandidate] = []
        for album in albums {
            let scored = CandidateScorer.score(
                albumTitle:    album.album,
                albumComposer: album.composer ?? "",
                albumArtist:   album.artist ?? "",
                ooTitle:       work.title,
                ooComposerName: composer.complete_name,
                lmsWorkTag:    nil
            )
            guard scored.confidence > 0.30 else { continue }
            results.append(WorkRecordingCandidate(
                id: "fallback-\(album.id)",
                openOpusWorkID: work.id,
                composerName: composer.complete_name,
                workTitle: work.title,
                lmsAlbumID: album.id,
                lmsAlbumName: album.album,
                lmsTrackIDs: [],
                artworkTrackID: album.artwork_track_id,
                confidence: scored.confidence,
                matchReason: scored.matchReason,
                source: .fallback,
                userOverride: false,
                performerSummary: album.artist
            ))
        }
        return results.sorted { $0.confidence > $1.confidence }
    }
}
