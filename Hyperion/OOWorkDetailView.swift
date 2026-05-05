import SwiftUI

// OpenOpus work detail — separate from the LMS WorkDetailView in LibraryView.swift.

struct OOWorkDetailView: View {

    let work: OOWork
    let composer: OOComposer

    @StateObject private var vm: OOWorkDetailViewModel
    @ObservedObject  private var player  = PlayerViewModel.shared

    @State private var matchedAlbum: Album? = nil
    @State private var isSearchingLibrary: Bool = false

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

                librarySection
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
        .task(id: work.id) { await searchLibrary() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
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

    // MARK: - Library section

    @ViewBuilder
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN YOUR LIBRARY")
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(.roonAccent)
                .kerning(1.2)
                .padding(.horizontal, 16)

            if isSearchingLibrary {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8).tint(.roonAccent)
                    Text("Searching library…")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                }
                .padding(.horizontal, 16)
            } else if let album = matchedAlbum {
                Button {
                    Task {
                        let tracks = try? await LyrionAPI.shared.getTracksForAlbum(albumID: album.id)
                        guard let tracks, !tracks.isEmpty else { return }
                        let groups = LyrionAPI.shared.groupTracksByWork(tracks)
                        if groups.isEmpty {
                            player.playSingleTrack(tracks[0])
                        } else {
                            player.playAlbum(groups)
                        }
                    }
                } label: {
                    HStack(spacing: 14) {
                        ArtworkView(coverid: album.artwork_track_id, size: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.album)
                                .font(.roonBody(14, weight: .medium))
                                .foregroundColor(.roonPrimary)
                                .lineLimit(1)
                            if let artist = album.artist ?? album.composer, !artist.isEmpty {
                                Text(artist)
                                    .font(.roonBody(12))
                                    .foregroundColor(.roonSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.roonAccent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.roonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            } else {
                Text("Not found in your library")
                    .font(.roonBody(13))
                    .foregroundColor(.roonTertiary)
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

    // MARK: - Library search

    private func searchLibrary() async {
        isSearchingLibrary = true
        matchedAlbum = nil
        let term = "\(composer.complete_name) \(work.title)"
        if let albums = try? await LyrionAPI.shared.searchAlbums(term: term, count: 20) {
            matchedAlbum = bestMatch(in: albums)
        }
        isSearchingLibrary = false
    }

    private func bestMatch(in albums: [Album]) -> Album? {
        var best: Album? = nil
        var bestScore: Double = 0.45
        for album in albums {
            let titleScore = work.title.similarity(album.album)
            let composerScore = composer.complete_name.similarity(album.composer ?? album.artist ?? "")
            let score = titleScore * 0.65 + composerScore * 0.35
            if score > bestScore { bestScore = score; best = album }
        }
        return best
    }

    private var composerPortraitURL: URL? {
        guard let p = composer.portrait, !p.isEmpty else { return nil }
        return URL(string: p)
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

    private let workID: String

    init(workID: String) { self.workID = workID }

    func load() async {
        guard detail == nil else { return }
        isLoading = true
        detail = try? await OpenOpusService.shared.workDetail(workID)
        isLoading = false
    }
}
