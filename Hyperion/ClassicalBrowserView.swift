import SwiftUI

// MARK: - Classical Browser

struct ClassicalBrowserView: View {

    @StateObject private var vm = ClassicalBrowserViewModel()
    @ObservedObject private var player = PlayerViewModel.shared
    @ObservedObject private var library = LibraryViewModel.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                epochFilter
                composerContent
            }
            .searchable(text: $vm.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search composers")
            .onChange(of: vm.searchText) { _, _ in vm.search() }
            .navigationTitle("Classical")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Color.roonBase.ignoresSafeArea())
        }
        .task { await vm.loadRecommended() }
    }

    // MARK: - Epoch filter chips

    private var epochFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OOEpoch.allCases) { epoch in
                    Button {
                        vm.selectEpoch(epoch)
                    } label: {
                        Text(epoch.rawValue)
                            .font(.roonBody(12, weight: vm.selectedEpoch == epoch ? .semibold : .regular))
                            .foregroundColor(vm.selectedEpoch == epoch ? .roonBase : .roonSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(vm.selectedEpoch == epoch ? Color.roonAccent : Color.roonElevated)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Composer grid

    @ViewBuilder
    private var composerContent: some View {
        if vm.isLoading && vm.composers.isEmpty {
            Spacer()
            ProgressView().tint(.roonAccent)
            Spacer()
        } else if vm.composers.isEmpty && !vm.isLoading {
            Spacer()
            Text("No composers found")
                .font(.roonBody(14))
                .foregroundColor(.roonTertiary)
            Spacer()
        } else {
            let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 14)]
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(vm.composers) { composer in
                        NavigationLink {
                            ComposerWorksView(composer: composer)
                        } label: {
                            ComposerGridCard(composer: composer)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Composer grid card

struct ComposerGridCard: View {

    let composer: OOComposer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Portrait
            AsyncImage(url: portraitURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    composerPlaceholder
                case .empty:
                    Color.roonElevated.overlay(ProgressView().tint(.roonTertiary))
                @unknown default:
                    composerPlaceholder
                }
            }
            .frame(height: 160)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(composer.complete_name)
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                if let epoch = composer.epoch, !epoch.isEmpty {
                    Text(epoch)
                        .font(.roonBody(11))
                        .foregroundColor(.roonAccent)
                }
            }
            .padding(10)
        }
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var portraitURL: URL? {
        guard let p = composer.portrait, !p.isEmpty else { return nil }
        return URL(string: p)
    }

    private var composerPlaceholder: some View {
        ZStack {
            Color.roonElevated
            Text(NameFormatting.initials(composer.complete_name))
                .font(.roonTitle(36))
                .foregroundColor(.roonAccent)
        }
    }
}

// MARK: - Composer Works View

struct ComposerWorksView: View {

    let composer: OOComposer
    @StateObject private var vm: ComposerWorksViewModel

    init(composer: OOComposer) {
        self.composer = composer
        _vm = StateObject(wrappedValue: ComposerWorksViewModel(composerID: composer.id))
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.groupedWorks.isEmpty {
                ProgressView().tint(.roonAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(vm.groupedWorks.keys.sorted()), id: \.self) { genre in
                        Section(genre) {
                            ForEach(vm.groupedWorks[genre] ?? []) { work in
                                WorkRow(work: work, composer: composer)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(composer.complete_name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await vm.load() }
    }
}

// MARK: - Work Row

struct WorkRow: View {

    let work: OOWork
    let composer: OOComposer
    @ObservedObject private var player = PlayerViewModel.shared
    @ObservedObject private var library = LibraryViewModel.shared
    @State private var matchState: MatchState = .idle

    enum MatchState {
        case idle, searching, found(Album), notFound
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if work.isPopular {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.roonAccent)
                    }
                    Text(work.title)
                        .font(.roonBody(13, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                }
                if let genre = work.genre {
                    Text(genre)
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                }
            }

            Spacer()

            matchButton
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var matchButton: some View {
        switch matchState {
        case .idle:
            Button {
                findAndPlay()
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.roonAccent)
            }
            .buttonStyle(.plain)

        case .searching:
            ProgressView()
                .scaleEffect(0.8)
                .tint(.roonAccent)

        case .found:
            Button {
                if case .found(let album) = matchState { playAlbum(album) }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.roonAccent)
            }
            .buttonStyle(.plain)

        case .notFound:
            Text("Not in library")
                .font(.roonBody(10))
                .foregroundColor(.roonTertiary)
        }
    }

    private func findAndPlay() {
        matchState = .searching
        Task {
            let result = await fuzzyMatchWork(title: work.title, composerName: composer.complete_name)
            await MainActor.run {
                if let album = result {
                    matchState = .found(album)
                    playAlbum(album)
                } else {
                    matchState = .notFound
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run { if case .notFound = matchState { matchState = .idle } }
                    }
                }
            }
        }
    }

    private func playAlbum(_ album: Album) {
        Task {
            let tracks = try? await LyrionAPI.shared.getTracksForAlbum(albumID: album.id)
            guard let tracks, !tracks.isEmpty else { return }
            let workGroups = LyrionAPI.shared.groupTracksByWork(tracks)
            if workGroups.isEmpty {
                player.playSingleTrack(tracks[0])
            } else {
                player.playAlbum(workGroups)
            }
        }
    }

    private func fuzzyMatchWork(title: String, composerName: String) async -> Album? {
        // Try to find the album in the LMS library using fuzzy matching.
        let searchTerm = "\(composerName) \(title)"
        guard let albums = try? await LyrionAPI.shared.searchAlbums(term: searchTerm, count: 20) else {
            return nil
        }

        var bestAlbum: Album? = nil
        var bestScore: Double = 0.5    // minimum threshold

        for album in albums {
            let albumText = "\(album.album) \(album.composer ?? album.artist ?? "")"
            let titleScore     = title.similarity(album.album)
            let composerScore  = composerName.similarity(album.composer ?? album.artist ?? "")
            let combinedScore  = (titleScore * 0.7 + composerScore * 0.3)

            // Also check if album title contains major words from work title
            let workWords = title.lowercased().split(whereSeparator: \.isWhitespace)
            let albumLower = albumText.lowercased()
            let wordMatchScore = workWords.isEmpty ? 0.0 :
                Double(workWords.filter { albumLower.contains($0) }.count) / Double(workWords.count)

            let score = max(combinedScore, wordMatchScore * 0.8)

            if score > bestScore {
                bestScore = score
                bestAlbum = album
            }
        }
        return bestAlbum
    }
}

// MARK: - ViewModels

@MainActor
final class ClassicalBrowserViewModel: ObservableObject {
    @Published var composers: [OOComposer] = []
    @Published var isLoading: Bool = false
    @Published var selectedEpoch: OOEpoch = .all
    @Published var searchText: String = ""

    private var searchTask: Task<Void, Never>? = nil

    func loadRecommended() async {
        guard composers.isEmpty else { return }
        isLoading = true
        composers = (try? await OpenOpusService.shared.recommendedComposers()) ?? []
        isLoading = false
    }

    func selectEpoch(_ epoch: OOEpoch) {
        guard selectedEpoch != epoch else { return }
        selectedEpoch = epoch
        searchText = ""
        Task { await loadForEpoch(epoch) }
    }

    func search() {
        searchTask?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty {
            Task { await loadForEpoch(selectedEpoch) }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isLoading = true
            composers = (try? await OpenOpusService.shared.searchComposers(name: term)) ?? []
            isLoading = false
        }
    }

    private func loadForEpoch(_ epoch: OOEpoch) async {
        isLoading = true
        if epoch == .all {
            composers = (try? await OpenOpusService.shared.recommendedComposers()) ?? []
        } else {
            composers = (try? await OpenOpusService.shared.composersByEpoch(epoch)) ?? []
        }
        isLoading = false
    }
}

@MainActor
final class ComposerWorksViewModel: ObservableObject {
    @Published var groupedWorks: [String: [OOWork]] = [:]
    @Published var isLoading = false

    let composerID: String

    init(composerID: String) {
        self.composerID = composerID
    }

    func load() async {
        guard groupedWorks.isEmpty else { return }
        isLoading = true
        let works = (try? await OpenOpusService.shared.works(composerID: composerID)) ?? []
        var grouped: [String: [OOWork]] = [:]
        for work in works {
            let genre = work.genre ?? "Other"
            grouped[genre, default: []].append(work)
        }
        // Sort works within each genre, popular first
        for key in grouped.keys {
            grouped[key]?.sort { $0.isPopular && !$1.isPopular }
        }
        groupedWorks = grouped
        isLoading = false
    }
}

// MARK: - Compact composer card for HomeView

struct ClassicalComposerCard: View {
    let composer: OOComposer

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: portraitURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                case .failure, .empty:
                    ZStack {
                        Circle()
                            .fill(Color.roonElevated)
                            .frame(width: 72, height: 72)
                        Text(NameFormatting.initials(composer.complete_name))
                            .font(.roonTitle(22))
                            .foregroundColor(.roonAccent)
                    }
                @unknown default:
                    Circle().fill(Color.roonElevated).frame(width: 72, height: 72)
                }
            }
            .frame(width: 72, height: 72)

            Text(NameFormatting.lastName(composer.complete_name))
                .font(.roonBody(11, weight: .medium))
                .foregroundColor(.roonSecondary)
                .lineLimit(1)
                .frame(width: 80)
        }
        .contentShape(Rectangle())
    }

    private var portraitURL: URL? {
        guard let p = composer.portrait, !p.isEmpty else { return nil }
        return URL(string: p)
    }
}
