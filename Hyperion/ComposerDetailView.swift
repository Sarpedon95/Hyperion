import SwiftUI

// MARK: - Composer Detail (OpenOpus)

struct ComposerDetailView: View {

    let composer: OOComposer
    @StateObject private var vm: ComposerDetailViewModel

    init(composer: OOComposer) {
        self.composer = composer
        _vm = StateObject(wrappedValue: ComposerDetailViewModel(composer: composer))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                portraitHeader
                bioDates
                genreFilter
                worksList
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(composer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                favouriteButton
            }
        }
        .task { await vm.load() }
    }

    // MARK: - Portrait header

    private var portraitHeader: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: portraitURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    ZStack {
                        Color.roonElevated
                        Text(NameFormatting.initials(composer.complete_name))
                            .font(.roonTitle(72))
                            .foregroundColor(.roonAccent)
                    }
                @unknown default:
                    Color.roonElevated
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .clipped()

            // Gradient scrim for legibility
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: Color.roonBase.opacity(0.85), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(composer.complete_name)
                    .font(.roonTitle(26))
                    .foregroundColor(.roonPrimary)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                if let epoch = composer.epoch, !epoch.isEmpty {
                    Text(epoch)
                        .font(.roonBody(14, weight: .semibold))
                        .foregroundColor(epochColor(epoch))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Dates

    @ViewBuilder
    private var bioDates: some View {
        let birth = composer.birth
        let death = composer.death
        if (birth != nil && !(birth?.isEmpty ?? true)) || (death != nil && !(death?.isEmpty ?? true)) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(.roonTertiary)
                Text(dateString(birth: birth, death: death))
                    .font(.roonBody(13))
                    .foregroundColor(.roonSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Genre filter

    @ViewBuilder
    private var genreFilter: some View {
        if !vm.genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    genreChip("All", selected: vm.selectedGenre == nil) {
                        vm.selectGenre(nil)
                    }
                    ForEach(vm.genres) { genre in
                        genreChip(genre.name, selected: vm.selectedGenre == genre.name) {
                            vm.selectGenre(genre.name)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            Divider().background(Color.roonBorder)
        }
    }

    private func genreChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.roonBody(12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .roonBase : .roonSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.roonAccent : Color.roonElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Works list

    @ViewBuilder
    private var worksList: some View {
        if vm.isLoading && vm.displayedWorks.isEmpty {
            ProgressView().tint(.roonAccent).padding(40)
        } else if vm.displayedWorks.isEmpty {
            Text("No works found")
                .font(.roonBody(14))
                .foregroundColor(.roonTertiary)
                .padding(40)
        } else {
            VStack(spacing: 0) {
                ForEach(vm.displayedWorks) { work in
                    NavigationLink {
                        OOWorkDetailView(work: work, composer: composer)
                    } label: {
                        OOWorkRow(work: work, composer: composer)
                    }
                    .buttonStyle(.plain)
                    Divider().background(Color.roonBorder).padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var favouriteButton: some View {
        Button {
            // Future: persist favourites
        } label: {
            Image(systemName: "heart")
                .font(.system(size: 17))
                .foregroundColor(.roonSecondary)
        }
    }

    // MARK: - Helpers

    private var portraitURL: URL? {
        guard let p = composer.portrait, !p.isEmpty else { return nil }
        return URL(string: p)
    }

    private func dateString(birth: String?, death: String?) -> String {
        let b = birth.map { String($0.prefix(4)) } ?? ""
        let d = death.map { String($0.prefix(4)) } ?? ""
        switch (b.isEmpty, d.isEmpty) {
        case (false, false): return "\(b) – \(d)"
        case (false, true):  return "b. \(b)"
        default:             return ""
        }
    }
}

// MARK: - Work row inside ComposerDetailView

struct OOWorkRow: View {

    let work: OOWork
    let composer: OOComposer

    @ObservedObject private var player = PlayerViewModel.shared
    @State private var matchState: WorkMatchState = .idle

    enum WorkMatchState {
        case idle, searching, found(Album), notFound
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if work.isPopular {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.roonAccent)
                    }
                    Text(work.title)
                        .font(.roonBody(14, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let genre = work.genre, !genre.isEmpty {
                    Text(genre)
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                }
            }

            Spacer()

            playControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var playControl: some View {
        switch matchState {
        case .idle:
            Button { findAndPlay() } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 24))
                    .foregroundColor(.roonAccent)
            }
            .buttonStyle(.plain)

        case .searching:
            ProgressView().scaleEffect(0.75).tint(.roonAccent)

        case .found:
            Button {
                if case .found(let album) = matchState { playAlbum(album) }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.roonAccent)
            }
            .buttonStyle(.plain)

        case .notFound:
            Text("Not in library")
                .font(.roonBody(10))
                .foregroundColor(.roonTertiary)
                .frame(width: 60)
        }
    }

    private func findAndPlay() {
        matchState = .searching
        Task {
            let result = await fuzzyMatchWork(title: work.title, composerName: composer.complete_name)
            if let album = result {
                matchState = .found(album)
                playAlbum(album)
            } else {
                matchState = .notFound
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if case .notFound = matchState { matchState = .idle }
                }
            }
        }
    }

    private func playAlbum(_ album: Album) {
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
    }

    private func fuzzyMatchWork(title: String, composerName: String) async -> Album? {
        let term = "\(composerName) \(title)"
        guard let albums = try? await LyrionAPI.shared.searchAlbums(term: term, count: 20) else {
            return nil
        }
        var best: Album? = nil
        var bestScore: Double = 0.45
        for album in albums {
            let titleScore    = title.similarity(album.album)
            let composerScore = composerName.similarity(album.composer ?? album.artist ?? "")
            let combined      = titleScore * 0.7 + composerScore * 0.3
            let words         = title.lowercased().split(whereSeparator: \.isWhitespace)
            let albumLower    = album.album.lowercased()
            let wordHit       = words.isEmpty ? 0.0
                : Double(words.filter { albumLower.contains($0) }.count) / Double(words.count)
            let score = Swift.max(combined, wordHit * 0.8)
            if score > bestScore { bestScore = score; best = album }
        }
        return best
    }
}

// MARK: - ViewModel

@MainActor
final class ComposerDetailViewModel: ObservableObject {

    @Published var genres: [OOGenreInfo] = []
    @Published var allWorks: [OOWork] = []
    @Published var isLoading: Bool = false
    @Published var selectedGenre: String? = nil

    var displayedWorks: [OOWork] {
        guard let g = selectedGenre else { return allWorks }
        return allWorks.filter { $0.genre?.caseInsensitiveCompare(g) == .orderedSame }
    }

    private let composer: OOComposer

    init(composer: OOComposer) { self.composer = composer }

    func load() async {
        guard allWorks.isEmpty else { return }
        isLoading = true
        async let fetchGenres = OpenOpusService.shared.genresForComposer(composer.id)
        async let fetchWorks  = OpenOpusService.shared.worksForComposer(composer.id)
        genres = (try? await fetchGenres) ?? []
        var works = (try? await fetchWorks) ?? []
        works.sort { lhs, rhs in
            if lhs.isPopular != rhs.isPopular { return lhs.isPopular }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        allWorks = works
        isLoading = false
    }

    func selectGenre(_ genre: String?) {
        withAnimation(.easeInOut(duration: 0.15)) { selectedGenre = genre }
    }
}
