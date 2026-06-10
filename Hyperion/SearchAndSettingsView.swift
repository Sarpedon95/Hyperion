import SwiftUI
import UIKit

// MARK: - Recent search persistence

@MainActor
final class RecentSearchStore: ObservableObject {
    static let shared = RecentSearchStore()

    private let key      = "recentSearches_v1"
    private let maxCount = 10

    @Published private(set) var searches: [String] = []

    private init() {
        searches = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = searches.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        if updated.count > maxCount { updated = Array(updated.prefix(maxCount)) }
        searches = updated
        UserDefaults.standard.set(updated, forKey: key)
    }

    func remove(_ query: String) {
        searches.removeAll { $0 == query }
        UserDefaults.standard.set(searches, forKey: key)
    }

    func clear() {
        searches = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Search view model (persists across navigation pushes)

enum SearchScope: String, CaseIterable {
    case library = "Library"
    case all     = "All"
}

struct OOWorkResult: Identifiable {
    let work: OOWork
    let composer: OOComposer
    var id: String { work.id }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var results: (composers: [Composer], works: [Work], albums: [Album], artists: [Artist], tracks: [Track], genres: [Genre], playlists: [LocalPlaylist]) = ([], [], [], [], [], [], [])
    @Published var isSearching: Bool = false
    @Published var scope: SearchScope = .all
    @Published var ooComposers: [OOComposer] = []
    @Published var ooWorks: [OOWorkResult] = []
    // Qobuz + Deezer search results (admin only). Populated after local search
    // completes; cleared when the query is cleared.
    @Published var streamingSections: [SearchResultSection] = []

    private var searchTask: Task<Void, Never>? = nil
    private var ooSearchTask: Task<Void, Never>? = nil
    private var streamingSearchTask: Task<Void, Never>? = nil
    private var searchSequence: Int = 0

    private var cache: [String: LibraryViewModel.SearchResults] = [:]

    var hasResults: Bool {
        !results.composers.isEmpty || !results.works.isEmpty || !results.albums.isEmpty
            || !results.artists.isEmpty || !results.tracks.isEmpty
            || !results.genres.isEmpty || !results.playlists.isEmpty
            || !ooComposers.isEmpty || !ooWorks.isEmpty
            || !streamingSections.isEmpty
    }

    func performSearch(query: String, library: LibraryViewModel) {
        searchTask?.cancel()
        ooSearchTask?.cancel()
        streamingSearchTask?.cancel()
        searchSequence += 1
        let sequence = searchSequence
        let key = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            results = ([], [], [], [], [], [], [])
            ooComposers = []
            ooWorks = []
            streamingSections = []
            isSearching = false
            return
        }

        ooComposers = []
        ooWorks = []
        streamingSections = []

        // 1. Return cached results immediately if available.
        if let cached = cache[key] {
            results = filteredForClassicalMode(cached)
            isSearching = false
        } else {
            isSearching = true

            // 2. Show in-memory results immediately while waiting for the server.
            let local = library.searchLocal(query: key)
            let hasLocal = !local.composers.isEmpty || !local.works.isEmpty || !local.albums.isEmpty
                || !local.artists.isEmpty || !local.tracks.isEmpty
            if hasLocal {
                results = filteredForClassicalMode(local)
                isSearching = false  // server results will replace these silently
            }

            // 3. 150 ms debounce, then fetch from server (skipped in Library scope).
            searchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.searchSequence == sequence else { return }
                guard self.scope == .all else {
                    if !hasLocal { self.isSearching = false }
                    return
                }
                if !hasLocal { self.isSearching = true }
                let r = await library.search(query: key)
                guard !Task.isCancelled, self.searchSequence == sequence else { return }
                RecentSearchStore.shared.add(key)
                self.results = self.filteredForClassicalMode(r)
                self.isSearching = false
                self.cache[key] = r
            }
        }

        // 4. OpenOpus omnisearch in parallel (All scope only, same debounce).
        //    Skipped entirely when classical mode is off — OO is classical-only.
        ooSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.searchSequence == sequence else { return }
            guard self.scope == .all, ClassicalMode.isEnabled else { return }
            let raw = (try? await OpenOpusService.shared.omnisearch(key)) ?? []
            guard !Task.isCancelled, self.searchSequence == sequence else { return }
            self.ooComposers = raw.filter { $0.type == "composer" }.map { res in
                OOComposer(id: res.id, name: res.name, complete_name: res.name,
                           epoch: res.epoch, portrait: res.portrait, birth: nil, death: nil)
            }
            self.ooWorks = raw.filter { $0.type == "work" }.compactMap { res -> OOWorkResult? in
                guard let comp = res.composer else { return nil }
                let work = OOWork(id: res.id, title: res.name, subtitle: nil,
                                  searchterms: nil, popular: nil, recommended: nil, genre: nil)
                return OOWorkResult(work: work, composer: comp)
            }
        }

        // 5. Qobuz + Deezer search in parallel (admin only, same debounce as
        //    OpenOpus). Local results render first; streaming sections append
        //    underneath when ready.
        streamingSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.searchSequence == sequence else { return }
            guard UserSession.shared.isAdmin, self.scope == .all else { return }

            async let qTracks = QobuzClient.shared.search(query: key)
            async let dTracks = DeezerClient.shared.search(query: key)
            async let sTracks = SquidClient.shared.search(query: key)
            async let qAlbums = QobuzClient.shared.searchAlbums(query: key)
            async let dAlbums = DeezerClient.shared.searchAlbums(query: key)
            async let sAlbums = SquidClient.shared.searchAlbums(query: key)
            let (qt, dt, st, qa, da, sa) = await (qTracks, dTracks, sTracks, qAlbums, dAlbums, sAlbums)
            guard !Task.isCancelled, self.searchSequence == sequence else { return }

            await MainActor.run {
                ServerLogStore.shared.debug("[Streaming search] '\(key)' → Qobuz \(qt.count)t/\(qa.count)a, Deezer \(dt.count)t/\(da.count)a, Squid \(st.count)t/\(sa.count)a (admin=\(UserSession.shared.isAdmin), scope=\(self.scope.rawValue))")
            }

            self.streamingSections = [
                SearchResultSection(id: "qobuz",  title: "Qobuz",  source: .qobuz,  tracks: qt, albums: qa),
                SearchResultSection(id: "deezer", title: "Deezer", source: .deezer, tracks: dt, albums: da),
                SearchResultSection(id: "squid",  title: "Squid",  source: .squid,  tracks: st, albums: sa),
            ].filter { !$0.tracks.isEmpty || !$0.albums.isEmpty }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        ooSearchTask?.cancel()
        ooSearchTask = nil
        streamingSearchTask?.cancel()
        streamingSearchTask = nil
        isSearching = false
    }

    /// Strips classical result categories (composers + works) when classical
    /// mode is off, so the main Search tab never surfaces classical scopes.
    /// Albums / artists / tracks / genres / playlists are unaffected.
    private func filteredForClassicalMode(
        _ r: LibraryViewModel.SearchResults
    ) -> LibraryViewModel.SearchResults {
        guard !ClassicalMode.isEnabled else { return r }
        return (composers: [], works: [],
                albums: r.albums, artists: r.artists, tracks: r.tracks,
                genres: r.genres, playlists: r.playlists)
    }
}

// MARK: - Search

struct SearchView: View {

    @Binding var path: NavigationPath

    init(path: Binding<NavigationPath> = .constant(NavigationPath())) {
        _path = path
    }

    @ObservedObject private var library = LibraryViewModel.shared
    @StateObject private var vm = SearchViewModel()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Search")
                    .font(.roonTitle(34))
                    .foregroundColor(.roonPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                SearchInputField(text: $vm.searchText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                Picker("Scope", selection: $vm.scope) {
                    ForEach(SearchScope.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Group {
                    if vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SearchSuggestionsView(searchText: $vm.searchText)
                    } else if vm.isSearching {
                        ProgressView()
                            .tint(.roonAccent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !vm.hasResults {
                        NoResultsView(query: vm.searchText)
                    } else {
                        SearchResultsView(results: vm.results,
                                         ooComposers: vm.ooComposers,
                                         ooWorks: vm.ooWorks,
                                         streamingSections: vm.streamingSections)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onChange(of: vm.searchText) { _, newValue in
                vm.performSearch(query: newValue, library: library)
            }
            .onChange(of: vm.scope) { _, _ in
                vm.performSearch(query: vm.searchText, library: library)
            }
            .task {
                // Pre-warm fast stores (composers, artists, first album page).
                // loadSongs() is intentionally omitted — it fetches the entire
                // song library in pages and blocks search for several seconds on
                // large libraries. Track results come from the server search instead.
                async let composers: Void = library.loadComposers()
                async let artists:   Void = library.loadArtists()
                async let albums:    Void = library.loadAlbums()
                await composers; await artists; await albums
            }
        }
    }
}

// MARK: - Search input field

struct SearchInputField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.roonTertiary)
                .font(.system(size: 16))
            TextField("Artists, albums, songs…", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .foregroundColor(.roonPrimary)
                .font(.roonBody(16))
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.roonTertiary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Removes the current search query")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.roonSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(focused ? Color.roonAccent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private func composerInitials(_ name: String) -> String { NameFormatting.initials(name) }
private func composerLastName(_ name: String) -> String { NameFormatting.lastName(name) }

// MARK: - Suggestions

struct SearchSuggestionsView: View {

    @Binding var searchText: String
    @ObservedObject private var library       = LibraryViewModel.shared
    @ObservedObject private var recentSearches = RecentSearchStore.shared

    @AppStorage(ClassicalMode.defaultsKey) private var classicalModeEnabled: Bool = true

    private let pinnedNames = [
        "Bach", "Beethoven", "Brahms", "Mozart", "Schubert",
        "Tchaikovsky", "Mahler", "Bruckner", "Wagner", "Sibelius",
        "Handel", "Vivaldi", "Haydn", "Chopin", "Liszt"
    ]

    // PERF: rebuilt only when library.composers changes, not on every render.
    @State private var cachedPinnedComposers: [Composer] = []
    @State private var cachedOtherComposers:  [Composer] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {

                // MARK: Recent searches
                if !recentSearches.searches.isEmpty {
                    RecentSearchesSection(
                        searches: recentSearches.searches,
                        onSelect: { query in searchText = query },
                        onClear:  { recentSearches.clear() },
                        onRemove: { recentSearches.remove($0) }
                    )
                }

                // MARK: Genres
                if !library.genres.isEmpty {
                    GenresSection(genres: library.genres)
                }

                // MARK: Popular composers (classical — gated)
                if classicalModeEnabled, !cachedPinnedComposers.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Popular Composers")
                            .font(.roonTitle(22))
                            .foregroundColor(.roonPrimary)
                            .padding(.horizontal, 20)
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(cachedPinnedComposers) { composer in
                                NavigationLink {
                                    WorkListView(composerID: composer.id, composerName: composer.artist)
                                } label: {
                                    ComposerSuggestionCard(composer: composer)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // MARK: All composers (classical — gated)
                if classicalModeEnabled, !cachedOtherComposers.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("All Composers")
                                .font(.roonTitle(22))
                                .foregroundColor(.roonPrimary)
                            Spacer()
                            NavigationLink("See All") { ComposerListView() }
                                .font(.roonBody(14, weight: .semibold))
                                .foregroundColor(.roonAccent)
                        }
                        .padding(.horizontal, 20)
                        LazyVStack(spacing: 0) {
                            ForEach(cachedOtherComposers) { composer in
                                NavigationLink {
                                    WorkListView(composerID: composer.id, composerName: composer.artist)
                                } label: {
                                    ComposerSmallRow(composer: composer)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if composer.id != cachedOtherComposers.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if library.isLoadingComposers || library.isLoadingGenres {
                    HStack { Spacer(); ProgressView().tint(.roonAccent); Spacer() }
                }
                Spacer(minLength: 80)
            }
            .padding(.top, 4)
        }
        .background(Color.roonBase)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .onAppear {
            rebuildCaches(library.composers)
        }
        .onChange(of: library.composers) { _, composers in
            rebuildCaches(composers)
        }
        .task {
            if library.genres.isEmpty { await library.loadGenres() }
        }
    }

    private func rebuildCaches(_ composers: [Composer]) {
        let pinned = pinnedNames.compactMap { name in
            composers.first { SearchTextNormalizer.matches($0.artist, query: name) }
        }
        let pinnedIDs = Set(pinned.map(\.id))
        cachedPinnedComposers = pinned
        cachedOtherComposers  = Array(composers.filter { !pinnedIDs.contains($0.id) }.prefix(80))
    }
}

// MARK: - Recent searches section

private struct RecentSearchesSection: View {
    let searches: [String]
    let onSelect: (String) -> Void
    let onClear:  () -> Void
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent")
                    .font(.roonTitle(22))
                    .foregroundColor(.roonPrimary)
                Spacer()
                Button("Clear", action: onClear)
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonAccent)
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(Array(searches.enumerated()), id: \.element) { index, query in
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 14))
                            .foregroundColor(.roonTertiary)
                            .frame(width: 20)
                        Text(query)
                            .font(.roonBody(15))
                            .foregroundColor(.roonPrimary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            onRemove(query)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.roonTertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove recent search")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(query) }

                    if index < searches.count - 1 {
                        Color.roonBorder.frame(height: 0.5).padding(.leading, 46)
                    }
                }
            }
            .background(Color.roonSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Genres section

private struct GenresSection: View {
    let genres: [Genre]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private static let palette: [Color] = [
        .roonAccent, .orange, Color(red: 0.55, green: 0.35, blue: 0.9),
        Color(red: 0.9, green: 0.35, blue: 0.55), .mint, .cyan,
        Color(red: 0.85, green: 0.75, blue: 0.2), Color(red: 0.3, green: 0.75, blue: 0.4)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Genres")
                .font(.roonTitle(22))
                .foregroundColor(.roonPrimary)
                .padding(.horizontal, 20)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(genres.prefix(30)) { genre in
                    NavigationLink {
                        GenreAlbumListView(genre: genre)
                    } label: {
                        GenreCard(genre: genre, palette: Self.palette)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct GenreCard: View {
    let genre: Genre
    let palette: [Color]

    private var color: Color {
        palette[abs(genre.name.hashValue) % palette.count]
    }

    var body: some View {
        Text(genre.name)
            .font(.roonBody(12, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(color.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(color.opacity(0.45), lineWidth: 1)
            )
    }
}

struct ComposerSuggestionCard: View {
    let composer: Composer
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.roonElevated).frame(width: 44, height: 44)
                Text(composerInitials(composer.artist))
                    .font(.roonTitle(14))
                    .foregroundColor(.roonAccent)
            }
            Text(composerLastName(composer.artist))
                .font(.roonBody(15, weight: .medium))
                .foregroundColor(.roonPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ComposerSmallRow: View {
    let composer: Composer
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.roonElevated).frame(width: 38, height: 38)
                Text(composerInitials(composer.artist))
                    .font(.roonTitle(12))
                    .foregroundColor(.roonAccent)
            }
            .padding(.leading, 4)
            Text(composer.artist)
                .font(.roonBody(15, weight: .medium))
                .foregroundColor(.roonPrimary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    let results: (composers: [Composer], works: [Work], albums: [Album], artists: [Artist], tracks: [Track], genres: [Genre], playlists: [LocalPlaylist])
    var ooComposers: [OOComposer] = []
    var ooWorks: [OOWorkResult] = []
    var streamingSections: [SearchResultSection] = []
    @ObservedObject private var library = LibraryViewModel.shared
    @ObservedObject private var player  = PlayerViewModel.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {

                if !results.artists.isEmpty {
                    searchSection("ARTISTS") {
                        LazyVStack(spacing: 0) {
                            ForEach(results.artists) { artist in
                                NavigationLink {
                                    ArtistDetailView(artist: artist)
                                } label: {
                                    SearchArtistRow(artist: artist)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if artist.id != results.artists.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if !results.albums.isEmpty {
                    searchSection("ALBUMS") {
                        AlbumArtworkGrid(albums: results.albums, horizontalPadding: 16)
                    }
                }

                if !results.tracks.isEmpty {
                    searchSection("SONGS") {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.tracks.enumerated()), id: \.element.id) { idx, track in
                                Button {
                                    player.playTracks(results.tracks, startingAt: idx)
                                } label: {
                                    SearchTrackRow(track: track)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if track.id != results.tracks.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if !results.composers.isEmpty {
                    searchSection("COMPOSERS") {
                        LazyVStack(spacing: 0) {
                            ForEach(results.composers) { composer in
                                NavigationLink {
                                    WorkListView(composerID: composer.id, composerName: composer.artist)
                                } label: {
                                    ComposerSmallRow(composer: composer)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if composer.id != results.composers.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if !results.works.isEmpty {
                    searchSection("WORKS") {
                        LazyVStack(spacing: 0) {
                            ForEach(results.works) { work in
                                NavigationLink {
                                    WorkDetailView(work: work)
                                } label: {
                                    WorkRowView(work: work, showComposer: true)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if work.id != results.works.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 82)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if !results.genres.isEmpty {
                    searchSection("GENRES") {
                        LazyVStack(spacing: 0) {
                            ForEach(results.genres) { genre in
                                NavigationLink {
                                    GenreAlbumListView(genre: genre)
                                } label: {
                                    HStack(spacing: 14) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.roonElevated)
                                                .frame(width: 40, height: 40)
                                            Image(systemName: "music.note.list")
                                                .font(.system(size: 16))
                                                .foregroundColor(.roonAccent)
                                        }
                                        Text(genre.name)
                                            .font(.roonBody(15, weight: .medium))
                                            .foregroundColor(.roonPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.roonTertiary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if genre.id != results.genres.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 68)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if !results.playlists.isEmpty {
                    searchSection("PLAYLISTS") {
                        LazyVStack(spacing: 0) {
                            ForEach(results.playlists) { playlist in
                                NavigationLink {
                                    PlaylistDetailView(playlistID: playlist.id)
                                } label: {
                                    SearchPlaylistRow(playlist: playlist)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if playlist.id != results.playlists.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 68)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if !ooComposers.isEmpty {
                    searchSection("CLASSICAL COMPOSERS") {
                        LazyVStack(spacing: 0) {
                            ForEach(ooComposers) { composer in
                                NavigationLink {
                                    ComposerDetailView(composer: composer)
                                } label: {
                                    OOComposerSearchRow(composer: composer)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                if composer.id != ooComposers.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if !ooWorks.isEmpty {
                    searchSection("CLASSICAL WORKS") {
                        LazyVStack(spacing: 0) {
                            ForEach(ooWorks) { entry in
                                OOWorkSearchRow(work: entry.work, composer: entry.composer)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if entry.id != ooWorks.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                // MARK: - Streaming (Qobuz / Deezer) — admin only
                // Ordered after every local section so the library always wins
                // visual priority. SearchViewModel guarantees Qobuz precedes
                // Deezer in `streamingSections`.
                if UserSession.shared.isAdmin {
                    ForEach(streamingSections) { section in
                        if !section.albums.isEmpty {
                            searchSection("\(section.title.uppercased()) — ALBUMS") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 12) {
                                        ForEach(section.albums) { album in
                                            NavigationLink(destination: StreamingAlbumView(album: album)) {
                                                StreamAlbumCard(album: album)
                                                    .frame(width: 140)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                        if !section.tracks.isEmpty {
                            searchSection(section.title.uppercased()) {
                                LazyVStack(spacing: 0) {
                                    ForEach(section.tracks) { track in
                                        StreamTrackRow(track: track)
                                            .padding(.horizontal, 14)
                                        if track.id != section.tracks.last?.id {
                                            Color.roonBorder.frame(height: 0.5).padding(.leading, 70)
                                        }
                                    }
                                }
                                .background(Color.roonSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }

                Spacer(minLength: 80)
            }
            .padding(.top, 4)
        }
        .background(Color.roonBase)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
    }

    @ViewBuilder
    private func searchSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchSectionTitle(title)
            content()
        }
    }
}

// MARK: - Search row components

struct SearchArtistRow: View {
    let artist: Artist

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.roonElevated)
                    .frame(width: 40, height: 40)
                Text(NameFormatting.initials(artist.name))
                    .font(.roonTitle(13))
                    .foregroundColor(.roonAccent)
            }
            Text(artist.name)
                .font(.roonBody(15, weight: .medium))
                .foregroundColor(.roonPrimary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct SearchTrackRow: View {
    let track: Track
    @ObservedObject private var player = PlayerViewModel.shared
    @State private var navigateToAlbum: Album? = nil

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(coverid: track.coverid, size: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // Streaming service badge (small, for compact row)
                if track.detectedService != .local {
                    StreamingServiceBadge(service: track.detectedService, size: 40 * 0.2)
                        .padding(2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(player.currentTrack?.id == track.id ? .roonAccent : .roonPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let artist = track.trackartist ?? track.albumartist, !artist.isEmpty {
                        Text(artist)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                    }
                    if let albumName = track.album, !albumName.isEmpty {
                        Text("·")
                            .font(.roonBody(12))
                            .foregroundColor(.roonTertiary)
                        Button {
                            if let albumID = track.albumID,
                               let album = LibraryViewModel.shared.albums.first(where: { $0.id == albumID }) {
                                navigateToAlbum = album
                            }
                        } label: {
                            Text(albumName)
                                .font(.roonBody(12))
                                .foregroundColor(.roonAccent.opacity(0.8))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            Image(systemName: "play.fill")
                .font(.system(size: 11))
                .foregroundColor(.roonTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .sheet(item: $navigateToAlbum) { album in
            NavigationStack { AlbumDetailView(album: album) }
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
    }
}

struct SearchPlaylistRow: View {
    let playlist: LocalPlaylist

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.roonElevated)
                    .frame(width: 40, height: 40)
                Image(systemName: "music.note.list")
                    .font(.system(size: 16))
                    .foregroundColor(.roonAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                Text(playlist.subtitle)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct SearchSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.roonBody(11, weight: .semibold))
            .foregroundColor(.roonAccent)
            .kerning(1.4)
            .padding(.horizontal, 20)
            .padding(.top, 4)
    }
}

struct NoResultsView: View {
    let query: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.roonTertiary)
            Text("No results for \"\(query)\"")
                .font(.roonTitle(18))
                .foregroundColor(.roonPrimary)
            Text("Try searching by artist, album, song title, or composer")
                .font(.roonBody(14))
                .foregroundColor(.roonSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.roonBase)
    }
}

// MARK: - OO search result rows

private struct OOComposerSearchRow: View {
    let composer: OOComposer
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.roonElevated).frame(width: 38, height: 38)
                Text(NameFormatting.initials(composer.complete_name))
                    .font(.roonTitle(12))
                    .foregroundColor(.roonAccent)
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(composer.complete_name)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                if let epoch = composer.epoch, !epoch.isEmpty {
                    Text(epoch)
                        .font(.roonBody(12))
                        .foregroundColor(.roonTertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private struct OOWorkSearchRow: View {
    let work: OOWork
    let composer: OOComposer

    @State private var isResolving = false
    @State private var albumNav: AlbumNavRequest? = nil
    @State private var pickerNav: PickerNavRequest? = nil
    @State private var showNotFound = false

    var body: some View {
        Button { resolveAndNavigate() } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.roonElevated)
                        .frame(width: 38, height: 38)
                    Image(systemName: "music.note")
                        .font(.system(size: 14))
                        .foregroundColor(.roonAccent)
                }
                .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(work.title)
                        .font(.roonBody(14, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(composer.complete_name)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if isResolving {
                    ProgressView().scaleEffect(0.75).tint(.roonAccent)
                        .frame(width: 32)
                } else if showNotFound {
                    Text("Not found")
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.roonTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .navigationDestination(item: $albumNav) { req in
            AlbumDetailView(album: req.album, scrollToTrackID: req.firstTrackID, autoPlay: req.autoPlay)
        }
        .navigationDestination(item: $pickerNav) { req in
            WorkRecordingPickerView(workTitle: req.workTitle, composerName: req.composerName, entries: req.entries)
        }
    }

    private func resolveAndNavigate() {
        guard !isResolving else { return }
        isResolving = true
        Task {
            let vm = ComposerDetailViewModel(composer: composer)
            let nav = await vm.resolveLibraryDestination(work: work, composer: composer)
            switch nav {
            case .singleAlbum(let album, let firstTrackID, let autoPlay):
                albumNav = AlbumNavRequest(album: album, firstTrackID: firstTrackID, autoPlay: autoPlay)
            case .picker(let entries):
                pickerNav = PickerNavRequest(workID: work.id, workTitle: work.title,
                                            composerName: composer.complete_name, entries: entries)
            case .notFound:
                showNotFound = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    showNotFound = false
                }
            }
            isResolving = false
        }
    }
}

// MARK: - Settings

struct SettingsView: View {

    @ObservedObject private var connection    = ConnectionManager.shared
    @ObservedObject private var serverLogs   = ServerLogStore.shared
    @ObservedObject private var player       = PlayerViewModel.shared
    @ObservedObject private var playlistStore = PlaylistStore.shared
    @ObservedObject private var audiomuse    = AudiomuseManager.shared
    @ObservedObject private var lastFmAuth   = LastFmAuthManager.shared
    @ObservedObject private var discogsAuth    = DiscogsAuthManager.shared
    @ObservedObject private var profileManager = PlaybackProfileManager.shared
    @ObservedObject private var playerDirectory = LMSPlayerDirectory.shared
    @State private var showPlayerPicker: Bool = false
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ClassicalMode.defaultsKey) private var classicalModeEnabled: Bool = true
    @AppStorage(RadioMode.defaultsKey) private var radioModeEnabled: Bool = false

    @State private var localURL: String     = ""
    @State private var tailscaleURL: String = ""
    @State private var proxyURL: String     = ""
    @State private var selectedMode: ConnectionMode   = .auto
    @State private var isTestingConnection: Bool      = false
    @State private var connectionTestResult: Bool?    = nil
    @State private var connectionTestMessage: String? = nil
    @State private var logsCopied: Bool = false
    @State private var connectionTestTask: Task<Void, Never>? = nil
    @State private var connectionTestID: UUID? = nil

    // Last.fm login sheet
    @State private var showLastFmLogin: Bool   = false
    @State private var lastFmUsername: String  = ""
    @State private var lastFmPassword: String  = ""

    // Discogs login sheet
    @State private var showDiscogsLogin: Bool  = false
    @State private var discogsPATInput: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(ConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .foregroundColor(.roonPrimary)
                } header: { Text("CONNECTION MODE") }
                .listRowBackground(Color.roonSurface)

                Section {
                    SettingsTextField(label: "Home",      placeholder: "http://192.168.1.x:9000",   text: $localURL)
                    SettingsTextField(label: "Tailscale", placeholder: "http://100.x.x.x:9000",     text: $tailscaleURL)
                    SettingsTextField(label: "Remote",    placeholder: "https://lyrion.domain.com", text: $proxyURL)
                } header: { Text("SERVER ADDRESSES") } footer: {
                    Text("For remote use, enter your public HTTPS reverse-proxy URL or Tailscale URL. You can paste either the base URL or the full /jsonrpc.js endpoint; Hyperion normalizes it automatically.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Button { testConnection() } label: {
                        HStack {
                            Text("Test Connection").foregroundColor(.roonPrimary)
                            Spacer()
                            if isTestingConnection {
                                ProgressView().tint(.roonAccent)
                            } else if let result = connectionTestResult {
                                Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(result ? .green : .red)
                            }
                        }
                    }
                    .disabled(isTestingConnection)
                    if let connectionTestMessage {
                        Text(connectionTestMessage)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    HStack {
                        Text("Status").foregroundColor(.roonSecondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(connection.isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(connection.isConnected ? "Connected" : "Disconnected").foregroundColor(.roonPrimary)
                        }
                    }
                    HStack {
                        Text("Active URL").foregroundColor(.roonSecondary)
                        Spacer()
                        Text(connection.currentURL.isEmpty ? "Not set" : ServerLogStore.redactedURL(connection.currentURL))
                            .foregroundColor(.roonPrimary).lineLimit(1)
                            .font(.roonBody(13)).truncationMode(.middle)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last check").foregroundColor(.roonSecondary)
                        Text(connection.lastConnectionMessage)
                            .font(.roonBody(12))
                            .foregroundColor(.roonPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("STATUS") }
                .listRowBackground(Color.roonSurface)

                Section {
                    Button { showPlayerPicker = true } label: {
                        HStack {
                            Image(systemName: playerDirectory.isRoutingToHardware
                                              ? "hifispeaker.fill"
                                              : "iphone")
                                .foregroundColor(.roonAccent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Play to")
                                    .font(.roonBody(15, weight: .medium))
                                    .foregroundColor(.roonPrimary)
                                Text(playerDirectory.selectedPlayer?.name ?? "This iPhone")
                                    .font(.roonBody(12))
                                    .foregroundColor(.roonSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.roonTertiary)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                } header: { Text("LMS PLAYER") } footer: {
                    Text("Choose where playback commands are sent. Hyperion still plays on this iPhone; selecting an LMS hardware player additionally fires transport commands on that device.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    if serverLogs.entries.isEmpty {
                        Text("No server diagnostics yet")
                            .foregroundColor(.roonSecondary)
                    } else {
                        ForEach(Array(serverLogs.entries.suffix(10))) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayLine)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(logColor(entry.level))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    HStack {
                        Button(logsCopied ? "Copied" : "Copy Logs") {
                            UIPasteboard.general.string = serverLogs.exportText
                            logsCopied = true
                        }
                        .foregroundColor(.roonAccent)
                        Spacer()
                        Button("Clear") {
                            serverLogs.clear()
                            logsCopied = false
                        }
                        .foregroundColor(.roonSecondary)
                    }
                } header: { Text("SERVER DIAGNOSTICS") } footer: {
                    Text("These entries also go to the system Console through os.Logger and include URL, HTTP status, RPC failures, timeout, TLS, DNS, and proxy/upstream errors.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Button { playlistStore.syncServerPlaylists() } label: {
                        HStack {
                            Text("Sync Server Playlists").foregroundColor(.roonPrimary)
                            Spacer()
                            if playlistStore.isLoadingServerPlaylists {
                                ProgressView().tint(.roonAccent)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(.roonAccent)
                            }
                        }
                    }
                    .disabled(playlistStore.isLoadingServerPlaylists)
                    if let error = playlistStore.serverPlaylistError {
                        Text(error)
                            .font(.roonBody(12))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("LIBRARY SYNC") } footer: {
                    Text("Fetches all playlists stored on the LMS server. Changes made in Hyperion (create, delete, add tracks) are written back to LMS immediately.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                AudiomuseSectionView(audiomuse: audiomuse)
                    .listRowBackground(Color.roonSurface)

                HIPSettingsSection()
                    .listRowBackground(Color.roonSurface)

                // MARK: - Accounts

                Section {
                    // Last.fm
                    if lastFmAuth.isSignedIn {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last.fm").foregroundColor(.roonPrimary)
                                Text(lastFmAuth.username ?? "Connected")
                                    .font(.roonBody(12)).foregroundColor(.roonSecondary)
                            }
                            Spacer()
                            Button("Sign Out") { lastFmAuth.signOut() }
                                .font(.roonBody(13)).foregroundColor(.roonAccent)
                        }
                    } else {
                        Button {
                            lastFmUsername = ""
                            lastFmPassword = ""
                            showLastFmLogin = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Last.fm").foregroundColor(.roonPrimary)
                                    Text("Scrobble tracks and sync loves")
                                        .font(.roonBody(12)).foregroundColor(.roonSecondary)
                                }
                                Spacer()
                                Text("Sign In").font(.roonBody(13)).foregroundColor(.roonAccent)
                            }
                        }
                    }

                    // Discogs
                    if discogsAuth.isConnected {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Discogs").foregroundColor(.roonPrimary)
                                Text("Personal Access Token connected")
                                    .font(.roonBody(12)).foregroundColor(.roonSecondary)
                            }
                            Spacer()
                            Button("Disconnect") { discogsAuth.disconnect() }
                                .font(.roonBody(13)).foregroundColor(.roonAccent)
                        }
                    } else {
                        Button {
                            discogsPATInput = ""
                            showDiscogsLogin = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Discogs").foregroundColor(.roonPrimary)
                                    Text("Album metadata and release info")
                                        .font(.roonBody(12)).foregroundColor(.roonSecondary)
                                }
                                Spacer()
                                Text("Connect").font(.roonBody(13)).foregroundColor(.roonAccent)
                            }
                        }
                    }
                } header: { Text("ACCOUNTS") } footer: {
                    Text("Last.fm scrobbles tracks and syncs your loved songs. Discogs provides album release info and metadata.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Toggle(isOn: $player.useOrpheusEngine) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Orpheus Engine")
                                .foregroundColor(.roonPrimary)
                            Text(player.useOrpheusEngine
                                 ? "PCM audio decoded and routed through the Orpheus DSP chain."
                                 : "Compatibility mode — AVPlayer streams directly. Orpheus DSP inactive.")
                                .font(.roonBody(12))
                                .foregroundColor(.roonSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.roonAccent)
                } header: { Text("PLAYBACK ENGINE") } footer: {
                    Text("Orpheus is recommended. Disable only if you experience playback issues. AirPlay always uses Compatibility mode regardless of this setting.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                PlaybackProfilesSection(profileManager: profileManager)
                    .listRowBackground(Color.roonSurface)

                Section {
                    Toggle(isOn: $classicalModeEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Classical Mode")
                                .foregroundColor(.roonPrimary)
                            Text(classicalModeEnabled
                                 ? "Composers, works, conductors, ensembles and soloists live in the Classical tab."
                                 : "Classical content is hidden everywhere — Home, Library, Search and the Classical tab.")
                                .font(.roonBody(12))
                                .foregroundColor(.roonSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.roonAccent)
                } header: { Text("CLASSICAL MUSIC") } footer: {
                    Text("Turn this off if you don't use the classical features. Now Playing still shows classical tags for any classical track you play.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Toggle(isOn: $radioModeEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Radio")
                                .foregroundColor(.roonPrimary)
                            Text(radioModeEnabled
                                 ? "Internet radio stations appear in a dedicated Radio tab."
                                 : "The Radio tab is hidden.")
                                .font(.roonBody(12))
                                .foregroundColor(.roonSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.roonAccent)
                } header: { Text("INTERNET RADIO") } footer: {
                    Text("Stream free internet radio stations from RadioBrowser. Distinct from the auto-DJ radio that builds a queue from a track.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Toggle(isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "hyperion.journal.promptEnabled") },
                        set: { UserDefaults.standard.set($0, forKey: "hyperion.journal.promptEnabled") }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Journal Prompts").foregroundColor(.roonPrimary)
                            Text("Ask to add a note after each track")
                                .font(.roonBody(12)).foregroundColor(.roonSecondary)
                        }
                    }
                    .tint(.roonAccent)
                } header: { Text("LISTENING JOURNAL") }
                .listRowBackground(Color.roonSurface)

                Section {
                    NavigationLink(destination: HyperionOnboardingFlow()) {
                        HStack {
                            Text("Retune Profile").foregroundColor(.roonPrimary)
                            Spacer()
                            Text(UserDefaults.standard.string(forKey: "hyperion.profile.context") ?? "Not set")
                                .font(.roonBody(13)).foregroundColor(.roonSecondary)
                        }
                    }
                } header: { Text("LISTENING PROFILE") }
                .listRowBackground(Color.roonSurface)

                // MARK: - Admin Control Room
                // Streaming source priority editor — gated on isAdmin so a
                // non-admin user never sees streaming controls anywhere.
                if UserSession.shared.isAdmin {
                    Section {
                        NavigationLink(destination: StreamingCredentialsView()) {
                            HStack {
                                Text("Streaming Credentials").foregroundColor(.roonPrimary)
                                Spacer()
                                Image(systemName: "key.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.roonSecondary)
                            }
                        }
                        NavigationLink(destination: StreamingSourcePriorityView()) {
                            HStack {
                                Text("Source Priority").foregroundColor(.roonPrimary)
                                Spacer()
                                Text(PlaybackRouter.shared.sourcePriority
                                    .map { $0.capitalized }.joined(separator: " → "))
                                    .font(.roonBody(13)).foregroundColor(.roonSecondary)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                        }
                    } header: { Text("CONTROL ROOM") } footer: {
                        Text("Enter your Deezer ARL and Qobuz token / user ID / app secret. Source priority sets the order Hyperion resolves a stream URL — local is always tried first.")
                            .font(.roonBody(12)).foregroundColor(.roonTertiary)
                    }
                    .listRowBackground(Color.roonSurface)
                }

                Section {
                    HStack {
                        Text("Version").foregroundColor(.roonSecondary)
                        Spacer()
                        Text(appVersion).foregroundColor(.roonPrimary)
                    }
                    HStack {
                        Text("Engine").foregroundColor(.roonSecondary)
                        Spacer()
                        Text("Lyrion Music Server").foregroundColor(.roonPrimary)
                    }
                } header: { Text("ABOUT HYPERION") }
                .listRowBackground(Color.roonSurface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
            .background(Color.roonBase)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.roonBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveSettings(); dismiss() }
                        .foregroundColor(.roonAccent).fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.roonSecondary)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                localURL     = connection.localURL
                tailscaleURL = connection.tailscaleURL
                proxyURL     = connection.proxyURL
                selectedMode = connection.connectionMode
            }
            .onDisappear {
                connectionTestTask?.cancel()
                connectionTestTask = nil
                connectionTestID = nil
                isTestingConnection = false
            }
            .sheet(isPresented: $showLastFmLogin) {
                LastFmLoginSheet(username: $lastFmUsername, password: $lastFmPassword,
                                 isPresented: $showLastFmLogin)
            }
            .sheet(isPresented: $showDiscogsLogin) {
                DiscogsLoginSheet(pat: $discogsPATInput, isPresented: $showDiscogsLogin)
            }
            .sheet(isPresented: $showPlayerPicker) {
                LMSPlayerPickerView()
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func saveSettings() {
        let newLocal     = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTailscale = tailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newProxy     = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let didChange = newLocal != connection.localURL
            || newTailscale != connection.tailscaleURL
            || newProxy != connection.proxyURL
            || selectedMode != connection.connectionMode

        connection.localURL       = newLocal
        connection.tailscaleURL   = newTailscale
        connection.proxyURL       = newProxy
        connection.connectionMode = selectedMode
        connection.saveSettings()

        guard didChange else { return }

        // Clear server-scoped data so a changed LMS endpoint never shows stale
        // albums/artwork from the previous library while reconnecting.
        LibraryViewModel.shared.clearCache()
        ArtworkCache.shared.clear()
        connection.forceReconnect()
    }

    private func testConnection() {
        guard !isTestingConnection else { return }
        isTestingConnection  = true
        connectionTestResult = nil
        connectionTestMessage = nil
        logsCopied = false

        let mode  = selectedMode
        let local = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts    = tailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prox  = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)

        connectionTestTask?.cancel()
        let testID = UUID()
        connectionTestID = testID
        connectionTestTask = Task { @MainActor in
            defer {
                if connectionTestID == testID {
                    isTestingConnection = false
                    connectionTestTask = nil
                    connectionTestID = nil
                }
            }

            let probe: ConnectionProbeResult
            switch mode {
            case .local:
                probe = await ConnectionManager.probeBestServer(local, mode: .local)
            case .tailscale:
                probe = await ConnectionManager.probeBestServer(ts, mode: .tailscale)
            case .proxy:
                probe = await ConnectionManager.probeBestServer(prox, mode: .proxy)
            case .auto:
                let entries: [(String, ConnectionMode)] = [(local, .local), (ts, .tailscale), (prox, .proxy)]
                var seen = Set<String>()
                let candidates = entries
                    .flatMap { HyperionServerURL.candidateBases(for: $0.0, mode: $0.1) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                if candidates.isEmpty {
                    probe = await ConnectionManager.probeBestServer("")
                } else {
                    // Reuse ConnectionManager's optimized candidate race so the
                    // Settings test behaves like Auto connection resolution and
                    // does not create a separate URLSession/socket pool per URL.
                    if let result = await ConnectionManager.probeFirstSuccessful(candidates: candidates) {
                        probe = result
                    } else {
                        probe = await ConnectionManager.probeServer("")
                    }
                }
            }

            guard !Task.isCancelled, connectionTestID == testID else { return }
            connectionTestResult = probe.isSuccess
            connectionTestMessage = probe.summary
        }
    }

    private func logColor(_ level: ServerLogLevel) -> Color {
        switch level {
        case .debug: return .roonTertiary
        case .info:  return .roonPrimary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}

// MARK: - Playback Profiles Settings

private struct PlaybackProfilesSection: View {
    @ObservedObject var profileManager: PlaybackProfileManager
    @State private var expandedProfiles: Set<PlaybackProfile> = []

    var body: some View {
        Section {
            HStack {
                Text("Default Profile").foregroundColor(.roonPrimary)
                Spacer()
                // Classical is excluded — it activates automatically from the
                // Classical tab, not as a manual default.
                Picker("Default Profile", selection: $profileManager.globalDefaultProfile) {
                    ForEach(PlaybackProfile.allCases.filter { $0 != .classical }) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .tint(.roonAccent)
            }

            ForEach(PlaybackProfile.allCases) { profile in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedProfiles.contains(profile) },
                        set: { isOpen in
                            if isOpen { expandedProfiles.insert(profile) }
                            else { expandedProfiles.remove(profile) }
                        }
                    )
                ) {
                    ProfileSettingsDetail(profile: profile, profileManager: profileManager)
                } label: {
                    HStack(spacing: 8) {
                        Text(profile.displayName).foregroundColor(.roonPrimary)
                        Spacer()
                        profileBadges(profileManager.settings(for: profile))
                    }
                }
                .tint(.roonAccent)
            }
        } header: {
            Text("PLAYBACK PROFILES")
        } footer: {
            Text("Profiles are auto-detected from track genre tags; the default profile is the fallback. The Classical profile activates automatically while the Classical tab is open and restores your previous profile when you leave. Per-album overrides can be set from the album detail view.")
                .font(.roonBody(12)).foregroundColor(.roonTertiary)
        }
    }

    @ViewBuilder
    private func profileBadges(_ s: ProfileSettings) -> some View {
        HStack(spacing: 4) {
            if s.gaplessEnabled   { badge("Gapless") }
            if s.crossfadeEnabled { badge("Xfade") }
            if s.crossfeedEnabled { badge("Xfeed") }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.roonAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.roonAccent.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct ProfileSettingsDetail: View {
    let profile: PlaybackProfile
    @ObservedObject var profileManager: PlaybackProfileManager

    private var settings: ProfileSettings {
        profileManager.settings(for: profile)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.gaplessEnabled },
            set: { v in profileManager.updateSettings(for: profile) { $0.gaplessEnabled = v } }
        )) {
            Text("Gapless Playback").foregroundColor(.roonPrimary)
        }
        .tint(.roonAccent)

        Toggle(isOn: Binding(
            get: { settings.crossfadeEnabled },
            set: { v in profileManager.updateSettings(for: profile) { $0.crossfadeEnabled = v } }
        )) {
            Text("Crossfade").foregroundColor(.roonPrimary)
        }
        .tint(.roonAccent)

        if settings.crossfadeEnabled {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Duration").font(.roonBody(13)).foregroundColor(.roonSecondary)
                    Spacer()
                    Text(String(format: "%.1f s", settings.crossfadeDuration))
                        .font(.roonMono(13)).foregroundColor(.roonTertiary)
                }
                Slider(value: Binding(
                    get: { settings.crossfadeDuration },
                    set: { v in profileManager.updateSettings(for: profile) { $0.crossfadeDuration = v } }
                ), in: 0.5...12, step: 0.5)
                .tint(.roonAccent)
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text("Curve Shape").font(.roonBody(13)).foregroundColor(.roonSecondary)
                Picker("Curve Shape", selection: Binding(
                    get: { settings.crossfadeShape },
                    set: { v in profileManager.updateSettings(for: profile) { $0.crossfadeShape = v } }
                )) {
                    ForEach(CrossfadeShape.allCases) { shape in
                        Text(shape.rawValue).tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                CrossfadeShapePreview(shape: settings.crossfadeShape)
                    .frame(height: 52)
            }
            .padding(.vertical, 2)
        }

        Toggle(isOn: Binding(
            get: { settings.crossfeedEnabled },
            set: { v in profileManager.updateSettings(for: profile) { $0.crossfeedEnabled = v } }
        )) {
            Text("Crossfeed (BS2B)").foregroundColor(.roonPrimary)
        }
        .tint(.roonAccent)

        if settings.crossfeedEnabled {
            Picker("Preset", selection: Binding(
                get: { settings.crossfeedPreset },
                set: { v in profileManager.updateSettings(for: profile) { $0.crossfeedPreset = v } }
            )) {
                ForEach(CrossfeedPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .foregroundColor(.roonSecondary)
        }

        if !settings.gaplessEnabled {
            Picker("Gap Between Tracks", selection: Binding(
                get: { settings.interTrackGap },
                set: { v in profileManager.updateSettings(for: profile) { $0.interTrackGap = v } }
            )) {
                ForEach(InterTrackGap.allCases) { gap in
                    Text(gap.displayName).tag(gap)
                }
            }
            .pickerStyle(.menu)
            .foregroundColor(.roonSecondary)
        }

        Toggle(isOn: Binding(
            get: { settings.sampleRateConversionEnabled },
            set: { v in profileManager.updateSettings(for: profile) { $0.sampleRateConversionEnabled = v } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sample Rate Conversion").foregroundColor(.roonPrimary)
                Text("Resample to a fixed output rate. Disable to play at native sample rate.")
                    .font(.roonBody(12)).foregroundColor(.roonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.roonAccent)

        Toggle(isOn: Binding(
            get: { settings.replayGainEnabled },
            set: { v in profileManager.updateSettings(for: profile) { $0.replayGainEnabled = v }
                       PlayerViewModel.shared.pushReplayGainToDSP() }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ReplayGain").foregroundColor(.roonPrimary)
                Text("Normalize loudness from the track's ReplayGain tags. Only attenuates — never boosts — so there is no clipping risk.")
                    .font(.roonBody(12)).foregroundColor(.roonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.roonAccent)

        if settings.replayGainEnabled {
            Picker("Mode", selection: Binding(
                get: { settings.replayGainMode },
                set: { v in profileManager.updateSettings(for: profile) { $0.replayGainMode = v }
                           PlayerViewModel.shared.pushReplayGainToDSP() }
            )) {
                ForEach(ReplayGainMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pre-amp").font(.roonBody(13)).foregroundColor(.roonSecondary)
                    Spacer()
                    Text(String(format: "%+.1f dB", settings.replayGainPreamp))
                        .font(.roonMono(13)).foregroundColor(.roonTertiary)
                }
                Slider(value: Binding(
                    get: { settings.replayGainPreamp },
                    set: { v in profileManager.updateSettings(for: profile) { $0.replayGainPreamp = v }
                               PlayerViewModel.shared.pushReplayGainToDSP() }
                ), in: -12...12, step: 0.5)
                .tint(.roonAccent)
            }
            .padding(.vertical, 2)
        }
    }
}

struct SettingsTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.roonSecondary).frame(width: 70, alignment: .leading)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .foregroundColor(.roonPrimary)
        }
    }
}

// MARK: - AudioMuse settings section

private struct AudiomuseSectionView: View {

    @ObservedObject var audiomuse: AudiomuseManager
    @State private var isEnabled: Bool = AudiomuseManager.shared.isEnabled
    @State private var testResult: String? = nil
    @State private var isTesting: Bool = false

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Mixes (AudioMuse)")
                        .foregroundColor(.roonPrimary)
                    Text(audiomuse.audiomuseAvailable
                         ? "Plugin detected — AI-generated mixes active"
                         : "Plugin not detected — using local mix generation")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.roonAccent)
            .onChange(of: isEnabled) { _, newValue in
                audiomuse.isEnabled = newValue
                if newValue {
                    Task { await audiomuse.probeAndRefreshIfNeeded() }
                }
            }

            Button {
                isTesting = true
                testResult = nil
                Task {
                    testResult = await audiomuse.testConnection()
                    isTesting = false
                }
            } label: {
                HStack {
                    Text("Test AudioMuse Connection")
                        .foregroundColor(.roonPrimary)
                    Spacer()
                    if isTesting {
                        ProgressView().tint(.roonAccent)
                    } else {
                        Image(systemName: "network")
                            .foregroundColor(.roonAccent)
                    }
                }
            }
            .disabled(isTesting)

            if let result = testResult {
                Text(result)
                    .font(.roonBody(12))
                    .foregroundColor(result.contains("available") ? .green : .roonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = audiomuse.lastRefreshError {
                Text("Mix refresh error: \(error)")
                    .font(.roonBody(12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: { Text("AI MIXES") } footer: {
            Text("AudioMuse is an optional LMS plugin that generates AI mixes. When unavailable, Hyperion falls back to local mix generation. A 5-second timeout is used for all AudioMuse requests.")
                .font(.roonBody(12)).foregroundColor(.roonTertiary)
        }
    }
}

// MARK: - Last.fm Login Sheet

private struct LastFmLoginSheet: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var isPresented: Bool
    @ObservedObject private var auth = LastFmAuthManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                }
                .listRowBackground(Color.roonSurface)

                if let error = auth.authError {
                    Section {
                        Text(error)
                            .font(.roonBody(13))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowBackground(Color.roonSurface)
                }

                Section {
                    Button {
                        Task { await auth.signIn(username: username, password: password) }
                    } label: {
                        HStack {
                            Spacer()
                            if auth.isAuthenticating {
                                ProgressView().tint(.roonAccent)
                            } else {
                                Text("Sign In")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.roonAccent)
                            }
                            Spacer()
                        }
                    }
                    .disabled(auth.isAuthenticating || username.isEmpty || password.isEmpty)
                }
                .listRowBackground(Color.roonSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Sign in to Last.fm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundColor(.roonSecondary)
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: auth.isSignedIn) { _, signedIn in
                if signedIn { isPresented = false }
            }
        }
    }
}

// MARK: - Discogs Login Sheet

private struct DiscogsLoginSheet: View {
    @Binding var pat: String
    @Binding var isPresented: Bool
    @ObservedObject private var auth = DiscogsAuthManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Personal Access Token", text: $pat)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                } footer: {
                    Text("Generate a Personal Access Token at discogs.com → Settings → Developers. The token is stored securely in your device Keychain.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Button {
                        auth.connect(token: pat)
                        isPresented = false
                    } label: {
                        HStack {
                            Spacer()
                            Text("Connect")
                                .fontWeight(.semibold)
                                .foregroundColor(.roonAccent)
                            Spacer()
                        }
                    }
                    .disabled(pat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .listRowBackground(Color.roonSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Connect Discogs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundColor(.roonSecondary)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - HIP Settings Section

private struct HIPSettingsSection: View {
    @State private var customNames: [String] = HIPEnsembleClassifier.shared.userNames
    @State private var newEntry: String = ""

    var body: some View {
        Section {
            ForEach(Array(customNames.enumerated()), id: \.element) { _, name in
                Text(name)
                    .font(.roonBody(14))
                    .foregroundColor(.roonPrimary)
            }
            .onDelete { indices in
                customNames.remove(atOffsets: indices)
                HIPEnsembleClassifier.shared.userNames = customNames
            }

            HStack {
                TextField("Add conductor or ensemble…", text: $newEntry)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundColor(.roonPrimary)
                    .font(.roonBody(14))
                Button {
                    let trimmed = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !customNames.contains(trimmed.lowercased()) else { return }
                    customNames.append(trimmed.lowercased())
                    HIPEnsembleClassifier.shared.userNames = customNames
                    newEntry = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.roonAccent)
                }
                .buttonStyle(.plain)
                .disabled(newEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: { Text("CLASSICAL — HIP PERFORMERS") } footer: {
            Text("Hyperion tags recordings as Historically Informed Performance (HIP) when a conductor or ensemble name matches this list. Swipe to remove; tap + to add.")
                .font(.roonBody(12)).foregroundColor(.roonTertiary)
        }
    }
}

// MARK: - Crossfade Shape Preview

private struct CrossfadeShapePreview: View {
    let shape: CrossfadeShape

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let steps = 120
            let midX  = w / 2

            // Fade-out curve (white) — outgoing track volume
            var outPath = Path()
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let x = CGFloat(t) * midX
                let y = h - CGFloat(shape.gain(t: t, fadingOut: true)) * h
                if i == 0 { outPath.move(to: CGPoint(x: x, y: y)) }
                else       { outPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(outPath, with: .color(.white.opacity(0.75)), lineWidth: 1.5)

            // Fade-in curve (accent) — incoming track volume
            var inPath = Path()
            for i in 0...steps {
                let t = Float(i) / Float(steps)
                let x = midX + CGFloat(t) * midX
                let y = h - CGFloat(shape.gain(t: t, fadingOut: false)) * h
                if i == 0 { inPath.move(to: CGPoint(x: x, y: y)) }
                else       { inPath.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(inPath, with: .color(.roonAccent.opacity(0.85)), lineWidth: 1.5)

            // Centre divider
            var div = Path()
            div.move(to: CGPoint(x: midX, y: 0))
            div.addLine(to: CGPoint(x: midX, y: h))
            ctx.stroke(div, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }
        .background(Color.roonElevated.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Streaming Credentials (admin Control Room)
//
// Paste-in editor for the Deezer ARL and Qobuz token / user ID / app secret.
// Values are written to the Keychain (the same keys the clients read), so they
// never live in source or UserDefaults. Saving takes effect immediately.

private struct StreamingCredentialsView: View {
    @State private var deezerARL      = ""
    @State private var qobuzToken     = ""
    @State private var qobuzUserID    = ""
    @State private var qobuzSecret    = ""
    @State private var squidServerURL = ""
    @State private var squidUsername  = ""
    @State private var squidPassword  = ""
    @State private var savedAt: Date? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                credField("ARL cookie", text: $deezerARL)
            } header: { Text("DEEZER") } footer: {
                Text("The `arl` cookie value from a logged-in Deezer session. Needed to resolve and decrypt streams.")
                    .font(.roonBody(12)).foregroundColor(.roonTertiary)
            }
            .listRowBackground(Color.roonSurface)

            Section {
                credField("User Auth Token", text: $qobuzToken)
                credField("User ID",         text: $qobuzUserID)
                credField("App Secret (optional)", text: $qobuzSecret)
            } header: { Text("QOBUZ") } footer: {
                Text("Token + user ID are all you need — the app secret used to sign stream requests is detected automatically from Qobuz. Only fill in App Secret if auto-detection fails.")
                    .font(.roonBody(12)).foregroundColor(.roonTertiary)
            }
            .listRowBackground(Color.roonSurface)

            Section {
                credField("Server URL", text: $squidServerURL)
                credField("Username",   text: $squidUsername)
                credField("Password",   text: $squidPassword)
            } header: { Text("SQUID") } footer: {
                Text("Base URL of your SquidWTF (Subsonic-compatible) server plus your account credentials. Passwords are sent as a salted MD5 token, not in the clear.")
                    .font(.roonBody(12)).foregroundColor(.roonTertiary)
            }
            .listRowBackground(Color.roonSurface)

            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Spacer()
                        Text(savedAt == nil ? "Save" : "Saved")
                            .fontWeight(.semibold)
                            .foregroundColor(.roonAccent)
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.roonSurface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.roonBase)
        .navigationTitle("Streaming Credentials")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func credField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.roonBody(12)).foregroundColor(.roonSecondary)
            TextField("", text: text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.roonPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
        }
        .padding(.vertical, 2)
    }

    private func load() {
        deezerARL      = KeychainManager.shared.load(key: "deezer.arl")      ?? ""
        qobuzToken     = KeychainManager.shared.load(key: "qobuz.token")     ?? ""
        qobuzUserID    = KeychainManager.shared.load(key: "qobuz.userID")    ?? ""
        qobuzSecret    = KeychainManager.shared.load(key: "qobuz.secret")    ?? ""
        squidServerURL = KeychainManager.shared.load(key: "squid.serverURL") ?? ""
        squidUsername  = KeychainManager.shared.load(key: "squid.username")  ?? ""
        squidPassword  = KeychainManager.shared.load(key: "squid.password")  ?? ""
    }

    private func save() {
        func write(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { KeychainManager.shared.delete(key: key) }
            else { KeychainManager.shared.save(key: key, value: trimmed) }
        }
        write("deezer.arl",      deezerARL)
        write("qobuz.token",     qobuzToken)
        write("qobuz.userID",    qobuzUserID)
        write("qobuz.secret",    qobuzSecret)
        write("squid.serverURL", squidServerURL)
        write("squid.username",  squidUsername)
        write("squid.password",  squidPassword)
        savedAt = Date()
        Haptics.light()
    }
}

// MARK: - Streaming Source Priority (admin Control Room)
//
// Editor for PlaybackRouter.shared.sourcePriority. Local is pinned to the
// top of the list and is not movable; only Qobuz and Deezer can be reordered.
// Changes are written back to UserDefaults via the property wrapper and take
// effect the next time PlaybackRouter resolves a stream URL.

private struct StreamingSourcePriorityView: View {
    @State private var streamingOrder: [String] = []

    var body: some View {
        List {
            Section {
                HStack {
                    sourceIcon(for: "local")
                    Text("Local").foregroundColor(.roonPrimary)
                    Spacer()
                    Text("Always first")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)
            } header: { Text("PINNED") } footer: {
                Text("Hyperion always tries your LMS library first. Drag the streaming sources below into the order they should be consulted as fallbacks.")
                    .font(.roonBody(12)).foregroundColor(.roonTertiary)
            }

            Section {
                ForEach(streamingOrder, id: \.self) { key in
                    HStack {
                        sourceIcon(for: key)
                        Text(key.capitalized).foregroundColor(.roonPrimary)
                        Spacer()
                    }
                }
                .onMove(perform: move)
                .listRowBackground(Color.roonSurface)
            } header: { Text("STREAMING FALLBACKS") }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.roonBase)
        .navigationTitle("Source Priority")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { EditButton().foregroundColor(.roonAccent) }
        .onAppear { loadFromRouter() }
    }

    private func loadFromRouter() {
        let stored = PlaybackRouter.shared.sourcePriority
        // Strip "local" and keep only known streaming keys, preserving order.
        let known: Set<String> = ["qobuz", "deezer", "squid"]
        var ordered = stored.filter { known.contains($0) }
        // Backfill any missing source (e.g. if defaults were mutated externally).
        for k in known where !ordered.contains(k) { ordered.append(k) }
        streamingOrder = ordered
    }

    private func move(from source: IndexSet, to destination: Int) {
        streamingOrder.move(fromOffsets: source, toOffset: destination)
        PlaybackRouter.shared.sourcePriority = ["local"] + streamingOrder
    }

    @ViewBuilder
    private func sourceIcon(for key: String) -> some View {
        let color: Color = {
            switch key {
            case "qobuz":  return Color(red: 0,     green: 0.706, blue: 0.847)
            case "deezer": return Color(red: 0.937, green: 0.329, blue: 0.4)
            case "squid":  return Color(red: 0.2,   green: 0.8,   blue: 0.4)
            default:       return .roonAccent
            }
        }()
        let initial = key.prefix(1).uppercased()
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.18))
                .frame(width: 28, height: 28)
            Text(initial)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(color)
        }
        .padding(.trailing, 8)
    }
}
