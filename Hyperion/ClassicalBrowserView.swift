import SwiftUI

// MARK: - Classical home
//
// A Home-style landing page for classical content: recently played / added
// classical albums, plus horizontal rails for composers, conductors, ensembles
// and soloists. Each rail's "See All" pushes the corresponding full browser.

struct ClassicalBrowserView: View {

    @StateObject private var vm = ClassicalHomeViewModel()
    @ObservedObject private var library = LibraryViewModel.shared
    @State private var recentTab: RecentTab = .played

    enum RecentTab { case played, added }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {

                    header

                    recentActivitySection

                    composersRail
                    conductorsRail
                    ensemblesRail
                    soloistsRail

                    worksRow

                    Spacer(minLength: 40)
                }
            }
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .refreshable { await load(force: true) }
        }
        .task { await load(force: false) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Classical")
                .font(.roonTitle(32))
                .foregroundColor(.roonPrimary)
            Spacer()
            NavigationLink { ClassicalSearchTab() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19))
                    .foregroundColor(.roonSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Search classical")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: - Recent activity (classical albums only)

    @ViewBuilder
    private var recentActivitySection: some View {
        HStack(alignment: .center, spacing: 0) {
            HomeSectionHeader(label: "RECENT ACTIVITY", title: "History")
            Spacer()
            HStack(spacing: 0) {
                recentTabButton("Played", tab: .played)
                recentTabButton("Added", tab: .added)
            }
            .background(Color.roonSurface)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.roonBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)

        // Classical tab reads only the pre-split classical slice from the
        // repository — never the shared, undifferentiated lists.
        let albums = recentTab == .played
            ? library.classicalRecentlyPlayed
            : library.classicalRecentAlbums

        if albums.isEmpty {
            emptyCard(
                icon: recentTab == .played ? "clock.arrow.circlepath" : "plus.square.on.square",
                title: recentTab == .played ? "No recent classical plays" : "No recent classical additions",
                subtitle: "Classical albums you \(recentTab == .played ? "play" : "add") will appear here."
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: {
                            RecentAlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func recentTabButton(_ label: String, tab: RecentTab) -> some View {
        let isActive = recentTab == tab
        Button { withAnimation(.easeInOut(duration: 0.18)) { recentTab = tab } } label: {
            Text(label)
                .font(.roonBody(12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .roonPrimary : .roonTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isActive ? Color.roonElevated : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rails

    @ViewBuilder
    private var composersRail: some View {
        if !library.composers.isEmpty {
            railHeader("YOUR LIBRARY", "Composers") { ClassicalComposersScreen() }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(library.composers.prefix(25)) { composer in
                        NavigationLink {
                            WorkListView(composerID: composer.id, composerName: composer.artist)
                        } label: {
                            ComposerCircleCard(composer: composer)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var conductorsRail: some View {
        if !vm.conductors.isEmpty {
            railHeader("PERFORMERS", "Conductors") { ConductorBrowserView() }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(vm.conductors.prefix(25)) { conductor in
                        NavigationLink { ConductorDetailView(conductor: conductor) } label: {
                            ClassicalPersonCircle(name: conductor.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var ensemblesRail: some View {
        if !vm.ensembles.isEmpty {
            railHeader("PERFORMERS", "Ensembles") { EnsembleBrowserView() }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(vm.ensembles.prefix(25)) { ensemble in
                        NavigationLink { EnsembleDetailView(ensemble: ensemble) } label: {
                            ClassicalEnsembleRailCard(ensemble: ensemble)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var soloistsRail: some View {
        if !vm.soloists.isEmpty {
            railHeader("PERFORMERS", "Soloists") { SoloistBrowserView() }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(vm.soloists.prefix(25)) { soloist in
                        NavigationLink { SoloistDetailView(soloist: soloist) } label: {
                            ClassicalPersonCircle(name: soloist.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Works discovery

    private var worksRow: some View {
        NavigationLink { RandomWorksView() } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.roonElevated)
                        .frame(width: 52, height: 52)
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 22))
                        .foregroundColor(.roonAccent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Discover Works")
                        .font(.roonBody(16, weight: .semibold))
                        .foregroundColor(.roonPrimary)
                    Text("Explore works across your library")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.roonTertiary)
            }
            .padding(14)
            .background(Color.roonSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 32)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func railHeader<Dest: View>(
        _ label: String, _ title: String,
        @ViewBuilder destination: @escaping () -> Dest
    ) -> some View {
        HStack(alignment: .lastTextBaseline) {
            HomeSectionHeader(label: label, title: title)
            Spacer()
            NavigationLink(destination: destination()) {
                Text("See All")
                    .font(.roonBody(12, weight: .semibold))
                    .foregroundColor(.roonAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.roonAccent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                Text(subtitle)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func load(force: Bool) async {
        async let composers: Void   = library.loadComposers()
        async let recentPlayed: Void = library.loadRecentlyPlayed(force: force)
        async let recentAdded: Void  = library.loadRecentAlbums(force: force)
        async let performers: Void   = vm.load(force: force)
        _ = await (composers, recentPlayed, recentAdded, performers)
    }
}

// MARK: - Classical home rail cards

struct ClassicalPersonCircle: View {
    let name: String
    private let size: CGFloat = 80

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.roonElevated).frame(width: size, height: size)
                Text(NameFormatting.initials(name))
                    .font(.roonTitle(24))
                    .foregroundColor(.roonAccent)
            }
            Text(NameFormatting.lastName(name))
                .font(.roonBody(12, weight: .medium))
                .foregroundColor(.roonSecondary)
                .lineLimit(1)
                .frame(width: size + 16)
        }
        .contentShape(Rectangle())
    }
}

struct ClassicalEnsembleRailCard: View {
    let ensemble: Ensemble
    private let size: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.roonElevated)
                    .frame(width: size, height: size)
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 34))
                    .foregroundColor(.roonAccent)
            }
            Text(ensemble.name)
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.roonPrimary)
                .lineLimit(2)
                .frame(width: size, height: 36, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Classical home view model

@MainActor
final class ClassicalHomeViewModel: ObservableObject {

    @Published var conductors: [Conductor] = []
    @Published var ensembles:  [Ensemble]  = []
    @Published var soloists:   [SoloistEntry] = []

    private var didLoad = false

    func load(force: Bool) async {
        if didLoad && !force { return }
        didLoad = true

        async let c = LyrionAPI.shared.fetchAllConductors()
        async let e = LyrionAPI.shared.fetchAllEnsembles()
        async let s = LyrionAPI.shared.fetchAllSoloists()
        let (cc, ee, ss) = await (c, e, s)
        conductors = cc
        ensembles  = ee
        soloists   = ss

        // Build the OO↔LMS link index in the background on first open.
        LMSLibraryLinker.shared.startLinkingFromLibrary()
    }
}

// MARK: - Composers browse screen (OpenOpus grid)
//
// Reached from the Classical home "Composers → See All". Hosts the OpenOpus
// composer grid (portraits, epoch + alphabet filters, search).

private struct ClassicalComposersScreen: View {
    @StateObject private var vm = ClassicalBrowserViewModel()

    var body: some View {
        ComposersTab(vm: vm)
            .navigationTitle("Composers")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.roonBase, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Color.roonBase.ignoresSafeArea())
            .task { await vm.loadInitial() }
    }
}

// MARK: - Composers Tab

private struct ComposersTab: View {

    @ObservedObject var vm: ClassicalBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            epochFilter
            alphabetFilter
            composerContent
        }
        .searchable(text: $vm.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search composers")
        .onChange(of: vm.searchText) { _, _ in vm.search() }
    }

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
            .padding(.vertical, 8)
        }
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
        let selected = vm.selectedLetter == letter
        return Button { vm.selectLetter(letter) } label: {
            Text(String(letter))
                .font(.roonMono(13, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .roonBase : .roonTertiary)
                .frame(width: 28, height: 28)
                .background(selected ? Color.roonAccent : Color.clear)
                .clipShape(Circle())
                // FIXED: 44pt minimum tap target — invisible padding beyond the visible circle
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var composerContent: some View {
        if vm.isLoading && vm.composers.isEmpty {
            Spacer()
            ProgressView().tint(.roonAccent)
            Spacer()
        } else if vm.composers.isEmpty {
            Spacer()
            Text("No composers found")
                .font(.roonBody(14))
                .foregroundColor(.roonTertiary)
            Spacer()
        } else {
            let columns = [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 12)]
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.composers) { composer in
                        NavigationLink {
                            ComposerDetailView(composer: composer)
                        } label: {
                            ComposerGridCard(composer: composer)
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
    }
}

// MARK: - Search Tab (omnisearch)

private struct ClassicalSearchTab: View {

    @State private var searchText: String = ""
    @State private var results: [OOOmnisearchResult] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var loadMoreOffset: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            resultsList
        }
        .background(Color.roonBase.ignoresSafeArea())
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.roonTertiary)
            TextField("Composers, works, performers...", text: $searchText)
                .font(.roonBody(15))
                .foregroundColor(.roonPrimary)
                .onChange(of: searchText) { _, new in
                    loadMoreOffset = 0
                    runSearch(new, offset: 0)
                }
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

    @ViewBuilder
    private var resultsList: some View {
        if isSearching && results.isEmpty {
            Spacer()
            ProgressView().tint(.roonAccent)
            Spacer()
        } else if results.isEmpty && !searchText.isEmpty {
            Spacer()
            Text("No results for \"\(searchText)\"")
                .font(.roonBody(14))
                .foregroundColor(.roonTertiary)
            Spacer()
        } else if results.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundColor(.roonTertiary)
                Text("Search across composers,\nworks and performers")
                    .font(.roonBody(14))
                    .foregroundColor(.roonTertiary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        } else {
            List {
                ForEach(results) { result in
                    OmnisearchResultRow(result: result)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.roonBorder)
                }
                if !isSearching {
                    Button {
                        loadMoreOffset += 20
                        runSearch(searchText, offset: loadMoreOffset)
                    } label: {
                        Text("Load more")
                            .font(.roonBody(14))
                            .foregroundColor(.roonAccent)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        }
    }

    private func runSearch(_ text: String, offset: Int) {
        searchTask?.cancel()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            if offset == 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            isSearching = true
            let newResults = (try? await OpenOpusService.shared.omnisearch(text, offset: offset)) ?? []
            guard !Task.isCancelled else { isSearching = false; return }
            if offset == 0 {
                results = newResults
            } else {
                results += newResults
            }
            isSearching = false
        }
    }
}

private struct OmnisearchResultRow: View {
    let result: OOOmnisearchResult

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: result.type == "composer" ? 22 : 6)
                    .fill(Color.roonElevated)
                    .frame(width: 44, height: 44)
                if let url = result.portrait.flatMap(URL.init) {
                    CachedRemoteImage(url: url, size: 44) { Color.clear }
                        .frame(width: 44, height: 44)
                        .clipShape(result.type == "composer"
                            ? AnyShape(Circle())
                            : AnyShape(RoundedRectangle(cornerRadius: 6)))
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundColor(.roonAccent)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(result.type.capitalized)
                        .font(.roonBody(11))
                        .foregroundColor(.roonAccent)
                    if let epoch = result.epoch ?? result.composer?.epoch, !epoch.isEmpty {
                        Text("·")
                            .foregroundColor(.roonTertiary)
                            .font(.roonBody(11))
                        Text(epoch)
                            .font(.roonBody(11))
                            .foregroundColor(.roonTertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var iconName: String {
        switch result.type {
        case "composer":  return "person.crop.circle"
        case "work":      return "music.note"
        default:          return "person.wave.2"
        }
    }
}

// MARK: - Composer Grid Card

struct ComposerGridCard: View {

    let composer: OOComposer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedRemoteImage(url: portraitURL, size: 156) {
                placeholder
            }
            .frame(height: 156)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(composer.complete_name)
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                if let epoch = composer.epoch, !epoch.isEmpty {
                    Text(epoch)
                        .font(.roonBody(11))
                        .foregroundColor(epochColor(epoch))
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

    private var placeholder: some View {
        ZStack {
            Color.roonElevated
            Text(NameFormatting.initials(composer.complete_name))
                .font(.roonTitle(36))
                .foregroundColor(.roonAccent)
        }
    }
}

// MARK: - Cached portrait image

/// Wraps ArtworkCache for OpenOpus portrait URLs. Caches decoded UIImages in
/// the shared NSCache so repeated scrolls don't re-download the same portrait.
private struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: url?.absoluteString) {
            image = nil
            guard let url else { return }
            image = await ArtworkCache.shared.loadImage(
                url: url,
                targetPoints: size,
                scale: UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2
            )
        }
    }
}

// MARK: - Epoch color helper

func epochColor(_ epoch: String) -> Color {
    switch epoch.lowercased() {
    case "medieval", "renaissance":                     return Color(hex: "#8a7ec4")
    case "baroque":                                     return Color(hex: "#d4a042")
    case "classical":                                   return Color(hex: "#5b9ccc")
    case "early romantic", "romantic":                  return Color(hex: "#cc5b7a")
    case "late romantic":                               return Color(hex: "#c4558a")
    case "20th century", "post-war", "21st century":    return Color(hex: "#5bcc8a")
    default:                                            return .roonAccent
    }
}

// MARK: - ViewModel

@MainActor
final class ClassicalBrowserViewModel: ObservableObject {

    @Published var composers: [OOComposer] = []
    @Published var isLoading: Bool = false
    @Published var selectedEpoch: OOEpoch = .all
    @Published var selectedLetter: Character? = nil
    @Published var searchText: String = ""

    private var searchTask: Task<Void, Never>? = nil

    func loadInitial() async {
        guard composers.isEmpty else { return }
        isLoading = true
        composers = (try? await OpenOpusService.shared.recommendedComposers()) ?? []
        isLoading = false
        // Start building the OO↔LMS link index in the background the first
        // time the Classical section is opened. Subsequent opens within 6 h
        // are a no-op (freshness check is inside startLinkingFromLibrary).
        LMSLibraryLinker.shared.startLinkingFromLibrary()
    }

    func selectEpoch(_ epoch: OOEpoch) {
        guard selectedEpoch != epoch else { return }
        selectedEpoch = epoch
        selectedLetter = nil
        searchText = ""
        Task { await reload() }
    }

    func selectLetter(_ letter: Character) {
        if selectedLetter == letter {
            selectedLetter = nil
            Task { await reload() }
        } else {
            selectedLetter = letter
            selectedEpoch = .all
            searchText = ""
            Task { await loadByLetter(letter) }
        }
    }

    func search() {
        searchTask?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            Task { await reload() }
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

    private func reload() async {
        isLoading = true
        if selectedEpoch == .all {
            composers = (try? await OpenOpusService.shared.recommendedComposers()) ?? []
        } else {
            composers = (try? await OpenOpusService.shared.composersByEpoch(selectedEpoch)) ?? []
        }
        isLoading = false
    }

    private func loadByLetter(_ letter: Character) async {
        isLoading = true
        composers = (try? await OpenOpusService.shared.composersByLetter(letter)) ?? []
        isLoading = false
    }
}

