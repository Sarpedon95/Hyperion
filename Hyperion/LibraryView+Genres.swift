// Extracted from LibraryView.swift as part of the god-file split (audit
// phase 6). Contains the Genres list and per-genre album list views.
//
// Cross-file dependencies (all internal in the same app module):
//   - LibraryViewModel.shared, Album, Genre              (Models / VM)
//   - AlbumArtworkGrid                                   (LibraryView.swift)
//   - ArtworkCache, SearchTextNormalizer, Color.roon*, Font.roon*
//
// No private types in LibraryView.swift were used by these views, so the
// move is access-modifier-safe.

import SwiftUI

// MARK: - Genre list

struct GenreListView: View {

    @ObservedObject private var library = LibraryViewModel.shared
    @State private var searchText: String = ""
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    private var filtered: [Genre] {
        guard !searchNeedle.isEmpty else { return library.genres }
        return library.genres.filter { searchNeedle.matches($0.name) }
    }

    var body: some View {
        List {
            ForEach(filtered) { genre in
                NavigationLink {
                    GenreAlbumListView(genre: genre)
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.roonElevated)
                                .frame(width: 44, height: 44)
                            Image(systemName: "guitars")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.roonAccent)
                        }
                        Text(genre.name)
                            .font(.roonBody(16, weight: .medium))
                            .foregroundColor(.roonPrimary)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .searchable(text: $searchText, prompt: "Search genres")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay {
            if library.isLoadingGenres && library.genres.isEmpty {
                ProgressView().tint(.roonAccent)
            } else if !library.isLoadingGenres && library.genres.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "guitars")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No genres found")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                }
            }
        }
        .task {
            if library.genres.isEmpty { await library.loadGenres() }
        }
    }
}

// MARK: - Genre album list

struct GenreAlbumListView: View {

    let genre: Genre
    @State private var albums: [Album] = []
    @State private var isLoading: Bool = true

    var body: some View {
        ScrollView {
            AlbumArtworkGrid(albums: albums)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay {
            if isLoading {
                ProgressView().tint(.roonAccent)
            } else if albums.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No albums found")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                }
            }
        }
        .task(id: genre.id) {
            isLoading = true
            defer { isLoading = false }
            albums = (try? await LyrionAPI.shared.getAlbumsForGenre(genreID: genre.id)) ?? []
            albums.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        }
    }
}
