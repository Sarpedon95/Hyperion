import SwiftUI

// MARK: - Classical Browser (4-tab)

struct ClassicalBrowserView: View {

    @StateObject private var vm = ClassicalBrowserViewModel()
    @State private var selectedTab: ClassicalTab = .composers

    enum ClassicalTab: String, CaseIterable {
        case composers  = "Composers"
        case works      = "Works"
        case performers = "Performers"
        case search     = "Search"

        var icon: String {
            switch self {
            case .composers:  return "person.3"
            case .works:      return "music.quarternote.3"
            case .performers: return "person.wave.2"
            case .search:     return "magnifyingglass"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ClassicalTabBar(selected: $selectedTab)
                    .padding(.top, 4)

                switch selectedTab {
                case .composers:
                    ComposersTab(vm: vm)
                case .works:
                    WorksTab()
                case .performers:
                    PerformersTab()
                case .search:
                    ClassicalSearchTab()
                }
            }
            .navigationTitle("Classical")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Color.roonBase.ignoresSafeArea())
        }
        .task { await vm.loadInitial() }
    }
}

// MARK: - Tab bar

private struct ClassicalTabBar: View {
    @Binding var selected: ClassicalBrowserView.ClassicalTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ClassicalBrowserView.ClassicalTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { selected = tab }
                } label: {
                    VStack(spacing: 5) {
                        Text(tab.rawValue)
                            .font(.roonBody(13, weight: selected == tab ? .semibold : .regular))
                            .foregroundColor(selected == tab ? .roonPrimary : .roonTertiary)
                        Rectangle()
                            .fill(selected == tab ? Color.roonAccent : Color.clear)
                            .frame(height: 2)
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Color.roonBorder.frame(height: 0.5)
        }
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

// MARK: - Works Tab

private struct WorksTab: View {
    var body: some View {
        RandomWorksView()
    }
}

// MARK: - Performers Tab

private struct PerformersTab: View {

    @State private var searchText: String = ""
    @State private var results: [OOOmnisearchResult] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            performerSearchBar

            if isSearching {
                Spacer()
                ProgressView().tint(.roonAccent)
                Spacer()
            } else if results.isEmpty && !searchText.isEmpty {
                Spacer()
                Text("No performers found")
                    .font(.roonBody(14))
                    .foregroundColor(.roonTertiary)
                Spacer()
            } else if results.isEmpty {
                emptyState
            } else {
                List(results) { result in
                    PerformerRow(result: result)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.roonBorder)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
            }
        }
        .background(Color.roonBase.ignoresSafeArea())
    }

    private var performerSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.roonTertiary)
            TextField("Search performers...", text: $searchText)
                .font(.roonBody(15))
                .foregroundColor(.roonPrimary)
                .onChange(of: searchText) { _, new in runSearch(new) }
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.wave.2")
                .font(.system(size: 44))
                .foregroundColor(.roonTertiary)
            Text("Search for conductors,\nsoloists and ensembles")
                .font(.roonBody(14))
                .foregroundColor(.roonTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func runSearch(_ text: String) {
        searchTask?.cancel()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            let all = (try? await OpenOpusService.shared.omnisearch(text)) ?? []
            guard !Task.isCancelled else { isSearching = false; return }
            results = all.filter { $0.type == "performer" }
            isSearching = false
        }
    }
}

private struct PerformerRow: View {
    let result: OOOmnisearchResult

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.roonElevated)
                    .frame(width: 44, height: 44)
                if let url = result.portrait.flatMap(URL.init) {
                    CachedRemoteImage(url: url, size: 44) { Color.clear }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Text(NameFormatting.initials(result.name))
                        .font(.roonTitle(14))
                        .foregroundColor(.roonAccent)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                if let epoch = result.epoch, !epoch.isEmpty {
                    Text(epoch)
                        .font(.roonBody(12))
                        .foregroundColor(.roonAccent)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
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

// MARK: - Compact card for HomeView rows

struct ClassicalComposerCard: View {
    let composer: OOComposer

    var body: some View {
        VStack(spacing: 6) {
            CachedRemoteImage(url: portraitURL, size: 72) {
                ZStack {
                    Circle().fill(Color.roonElevated)
                    Text(NameFormatting.initials(composer.complete_name))
                        .font(.roonTitle(22))
                        .foregroundColor(.roonAccent)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

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
                scale: UIScreen.main.scale
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
