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

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var results: (composers: [Composer], works: [Work], albums: [Album], artists: [Artist], tracks: [Track], genres: [Genre], playlists: [LocalPlaylist]) = ([], [], [], [], [], [], [])
    @Published var isSearching: Bool = false

    private var searchTask: Task<Void, Never>? = nil
    private var searchSequence: Int = 0

    var hasResults: Bool {
        !results.composers.isEmpty || !results.works.isEmpty || !results.albums.isEmpty
            || !results.artists.isEmpty || !results.tracks.isEmpty
            || !results.genres.isEmpty || !results.playlists.isEmpty
    }

    func performSearch(query: String, library: LibraryViewModel) {
        searchTask?.cancel()
        searchSequence += 1
        let sequence = searchSequence
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = ([], [], [], [], [], [], [])
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self, self.searchSequence == sequence else { return }
            let r = await library.search(query: trimmed)
            guard !Task.isCancelled, self.searchSequence == sequence else { return }
            RecentSearchStore.shared.add(trimmed)
            self.results = r
            self.isSearching = false
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}

// MARK: - Search

struct SearchView: View {

    @ObservedObject private var library = LibraryViewModel.shared
    @StateObject private var vm = SearchViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Search")
                    .font(.roonTitle(34))
                    .foregroundColor(.roonPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                SearchInputField(text: $vm.searchText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

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
                        SearchResultsView(results: vm.results)
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
            .task {
                if library.composers.isEmpty { await library.loadComposers() }
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

                // MARK: Popular composers
                if !cachedPinnedComposers.isEmpty {
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

                // MARK: All composers
                if !cachedOtherComposers.isEmpty {
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
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
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
                        LazyVStack(spacing: 0) {
                            ForEach(results.albums) { album in
                                NavigationLink {
                                    AlbumDetailView(album: album)
                                } label: {
                                    AlbumListRow(album: album)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(DragGesture(minimumDistance: 0)
                                    .onChanged { _ in Task { try? await library.getTracksForAlbum(album.id) } }
                                )
                                if album.id != results.albums.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 68)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
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
            ArtworkView(coverid: track.coverid, size: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

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

// MARK: - Settings

struct SettingsView: View {

    @ObservedObject private var connection    = ConnectionManager.shared
    @ObservedObject private var serverLogs   = ServerLogStore.shared
    @ObservedObject private var player       = PlayerViewModel.shared
    @ObservedObject private var playlistStore = PlaylistStore.shared
    @ObservedObject private var audiomuse    = AudiomuseManager.shared
    @Environment(\.dismiss) private var dismiss

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

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Crossfade").foregroundColor(.roonPrimary)
                            Spacer()
                            Text(player.crossfadeDuration == 0
                                 ? "Off"
                                 : String(format: "%.1f s", player.crossfadeDuration))
                                .foregroundColor(.roonSecondary)
                                .monospacedDigit()
                        }
                        Slider(value: $player.crossfadeDuration, in: 0...12, step: 0.5)
                            .tint(.roonAccent)
                    }
                    .padding(.vertical, 4)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "waveform.path.badge.minus")
                            .foregroundColor(.roonSecondary)
                            .font(.system(size: 13))
                            .padding(.top, 1)
                        Text("Gapless playback is always active (AVPlayer path). Crossfade fades the current track out before the next one begins.")
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("PLAYBACK") } footer: {
                    Text("Crossfade applies to both the Orpheus DSP engine and AVPlayer paths.")
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
