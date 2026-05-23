import SwiftUI

// MARK: - Soloist browser
//
// Sourced from the ClassicalTags plugin (/plugins/ClassicalTags/soloists).
// If the plugin isn't installed yet — or no SOLOIST tags have been written
// to the library — the list is empty and the documented empty state shows.

struct SoloistBrowserView: View {

    @State private var allSoloists: [SoloistEntry] = []
    @State private var isLoading: Bool = true
    @State private var didLoadOnce: Bool = false
    @State private var searchText: String = ""

    private var filteredSoloists: [SoloistEntry] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return allSoloists }
        let needle = SearchTextNormalizer.Needle(term)
        return allSoloists.filter { needle.matches($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if isLoading && allSoloists.isEmpty {
                Spacer()
                ProgressView().tint(.roonAccent)
                Spacer()
            } else if filteredSoloists.isEmpty {
                emptyState
            } else {
                soloistList
            }
        }
        .background(Color.roonBase)
        .task { await loadIfNeeded() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.roonTertiary)
            TextField("Search soloists…", text: $searchText)
                .font(.roonBody(15))
                .foregroundColor(.roonPrimary)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.roonTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.roonElevated)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var soloistList: some View {
        List {
            ForEach(filteredSoloists) { soloist in
                NavigationLink {
                    SoloistDetailView(soloist: soloist)
                } label: {
                    SoloistRow(soloist: soloist)
                }
                .listRowBackground(Color.roonSurface)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.wave.2")
                .font(.system(size: 40))
                .foregroundColor(.roonTertiary)
            if didLoadOnce {
                Text("No soloist tags found yet.")
                    .font(.roonTitle(17))
                    .foregroundColor(.roonSecondary)
                Text("Tags are being added to your library — once the ClassicalTags plugin indexes SOLOIST fields they will appear here.")
                    .font(.roonBody(13))
                    .foregroundColor(.roonTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                ProgressView().tint(.roonAccent)
            }
            Spacer()
        }
    }

    private func loadIfNeeded() async {
        guard !didLoadOnce else { return }
        isLoading = true
        allSoloists = await LyrionAPI.shared.fetchAllSoloists()
        isLoading = false
        didLoadOnce = true
    }
}

// MARK: - Row

private struct SoloistRow: View {
    let soloist: SoloistEntry

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.roonElevated)
                    .frame(width: 44, height: 44)
                Image(systemName: "person.wave.2")
                    .foregroundColor(.roonAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(soloist.name)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                if soloist.trackCount > 0 {
                    Text("\(soloist.trackCount) track\(soloist.trackCount == 1 ? "" : "s")")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Soloist detail

struct SoloistDetailView: View {

    let soloist: SoloistEntry

    @State private var tracks: [Track] = []
    @State private var isLoading: Bool = true
    @State private var didLoadOnce: Bool = false

    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && tracks.isEmpty {
                Spacer()
                ProgressView().tint(.roonAccent)
                Spacer()
            } else if tracks.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No tracks found.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonTertiary)
                }
                Spacer()
            } else {
                trackList
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(soloist.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadIfNeeded() }
    }

    private var trackList: some View {
        List {
            ForEach(tracks) { track in
                Button {
                    player.playSingleTrack(track)
                } label: {
                    SoloistTrackRow(track: track)
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

    private func loadIfNeeded() async {
        guard !didLoadOnce else { return }
        isLoading = true
        tracks = await LyrionAPI.shared.fetchTracksWithSoloist(name: soloist.name)
        isLoading = false
        didLoadOnce = true
    }
}

private struct SoloistTrackRow: View {
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(coverid: track.coverid, size: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                if let work = track.work, !work.isEmpty {
                    Text(work)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let album = track.album, !album.isEmpty {
                        Text(album)
                            .font(.roonBody(11))
                            .foregroundColor(.roonTertiary)
                            .lineLimit(1)
                    }
                    if let year = track.year, year > 0 {
                        Text("·")
                            .font(.roonBody(11))
                            .foregroundColor(.roonTertiary)
                        Text(String(year))
                            .font(.roonMono(11))
                            .foregroundColor(.roonTertiary)
                    }
                }
            }
            Spacer()
            Text(track.durationFormatted)
                .font(.roonMono(11))
                .foregroundColor(.roonTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
