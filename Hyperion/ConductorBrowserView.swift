import SwiftUI

// MARK: - Conductor browser
//
// Same shape as EnsembleBrowserView, sourced from LMS role_id:3 contributors.
// Tap a conductor → ConductorDetailView (album grid with sort options).

struct ConductorBrowserView: View {

    @State private var allConductors: [Conductor] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""
    @State private var selectedLetter: Character? = nil

    private var filteredConductors: [Conductor] {
        var list = allConductors
        if let letter = selectedLetter {
            let target = String(letter).lowercased()
            list = list.filter { $0.name.lowercased().hasPrefix(target) }
        }
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            let needle = SearchTextNormalizer.Needle(term)
            list = list.filter { needle.matches($0.name) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            alphabetFilter

            if isLoading && allConductors.isEmpty {
                Spacer()
                ProgressView().tint(.roonAccent)
                Spacer()
            } else if filteredConductors.isEmpty {
                emptyState
            } else {
                conductorList
            }
        }
        .background(Color.roonBase)
        .task { await loadIfNeeded() }
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.roonTertiary)
            TextField("Search conductors…", text: $searchText)
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

    private var alphabetFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { letter in
                    letterButton(letter)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private func letterButton(_ letter: Character) -> some View {
        let selected = selectedLetter == letter
        return Button {
            selectedLetter = (selectedLetter == letter) ? nil : letter
        } label: {
            Text(String(letter))
                .font(.roonMono(13, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .roonBase : .roonTertiary)
                .frame(width: 28, height: 28)
                .background(selected ? Color.roonAccent : Color.clear)
                .clipShape(Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var conductorList: some View {
        List {
            ForEach(filteredConductors) { conductor in
                NavigationLink {
                    ConductorDetailView(conductor: conductor)
                } label: {
                    ConductorRow(conductor: conductor)
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
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundColor(.roonTertiary)
            Text("No conductors found")
                .font(.roonTitle(17))
                .foregroundColor(.roonSecondary)
            Text("Tag classical tracks with CONDUCTOR in LMS so they appear here.")
                .font(.roonBody(13))
                .foregroundColor(.roonTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func loadIfNeeded() async {
        guard allConductors.isEmpty else { return }
        isLoading = true
        allConductors = await LyrionAPI.shared.fetchAllConductors()
        isLoading = false
    }
}

// MARK: - Row

private struct ConductorRow: View {
    let conductor: Conductor

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.roonElevated)
                    .frame(width: 44, height: 44)
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.roonAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(conductor.name)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                if conductor.albumCount > 0 {
                    Text("\(conductor.albumCount) album\(conductor.albumCount == 1 ? "" : "s")")
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

// MARK: - Conductor detail

struct ConductorDetailView: View {

    let conductor: Conductor

    @State private var albums: [Album] = []
    @State private var isLoading: Bool = true
    @State private var sortOrder: ClassicalAlbumSort = .yearDescending

    private var sortedAlbums: [Album] {
        ClassicalAlbumSort.sorted(albums, by: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            ClassicalAlbumSortPicker(sortOrder: $sortOrder)

            if isLoading && albums.isEmpty {
                Spacer()
                ProgressView().tint(.roonAccent)
                Spacer()
            } else if sortedAlbums.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No albums credited to this conductor.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonTertiary)
                }
                Spacer()
            } else {
                albumGrid
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(conductor.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadIfNeeded() }
    }

    private var albumGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 12)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(sortedAlbums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        ClassicalAlbumGridCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
    }

    private func loadIfNeeded() async {
        guard albums.isEmpty else { return }
        isLoading = true
        albums = await LyrionAPI.shared.fetchAlbumsForConductor(conductorID: conductor.id)
        isLoading = false
    }
}
