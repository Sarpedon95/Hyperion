import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = PlaybackHistoryStore.shared
    @ObservedObject private var library = LibraryViewModel.shared
    @State private var selectedTab: HistoryTab = .recent

    enum HistoryTab: String, CaseIterable {
        case recent  = "Recent"
        case artists = "Artists"
        case genres  = "Genres"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(HistoryTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Color.roonBorder)

            switch selectedTab {
            case .recent:  recentList
            case .artists: artistList
            case .genres:  genreList
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentList: some View {
        let albums = history.recentlyPlayedAlbums(limit: 60)
        if albums.isEmpty {
            emptyState(icon: "clock.arrow.circlepath", text: "No plays recorded yet")
        } else {
            ScrollView {
                AlbumArtworkGrid(albums: albums)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
        }
    }

    // MARK: - Top Artists

    @ViewBuilder
    private var artistList: some View {
        let sorted = history.artistPlayCounts
            .sorted { $0.value > $1.value }
        if sorted.isEmpty {
            emptyState(icon: "person.crop.circle", text: "No artist data yet")
        } else {
            List {
                ForEach(Array(sorted.enumerated()), id: \.element.key) { rank, pair in
                    let artist = library.artists.first { $0.name == pair.key }
                        ?? Artist(id: 0, name: pair.key)
                    NavigationLink(destination: ArtistDetailView(artist: artist)) {
                        HistoryRankRow(
                            rank: rank + 1,
                            title: pair.key,
                            subtitle: pluralPlays(pair.value)
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.roonBorder)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
        }
    }

    // MARK: - Top Genres

    @ViewBuilder
    private var genreList: some View {
        let sorted = history.genrePlayCounts
            .sorted { $0.value > $1.value }
        if sorted.isEmpty {
            emptyState(icon: "guitars.fill", text: "No genre data yet")
        } else {
            let allGenres = library.genres
            List {
                ForEach(Array(sorted.enumerated()), id: \.element.key) { rank, pair in
                    let genre = allGenres.first { $0.name == pair.key }
                    if let genre {
                        NavigationLink(destination: GenreAlbumListView(genre: genre)) {
                            HistoryRankRow(
                                rank: rank + 1,
                                title: pair.key,
                                subtitle: pluralPlays(pair.value)
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.roonBorder)
                    } else {
                        HistoryRankRow(rank: rank + 1, title: pair.key, subtitle: pluralPlays(pair.value))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.roonBorder)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
        }
    }

    // MARK: - Helpers

    private func pluralPlays(_ n: Int) -> String {
        n == 1 ? "1 play" : "\(n) plays"
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.roonTertiary)
            Text(text)
                .font(.roonBody(16))
                .foregroundColor(.roonSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Rank row

private struct HistoryRankRow: View {
    let rank: Int
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.roonMono(14, weight: .semibold))
                .foregroundColor(.roonTertiary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
