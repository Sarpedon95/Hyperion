import SwiftUI

// Swipe-style discovery feed of random classical works.

struct RandomWorksView: View {

    @StateObject private var vm = RandomWorksViewModel()

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider().background(Color.roonBorder)
            content
        }
        .background(Color.roonBase.ignoresSafeArea())
        .task { await vm.load() }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterChip("All", selected: vm.selectedGenre == nil && vm.popularOnly == false) {
                vm.selectedGenre = nil
                vm.popularOnly   = false
                Task { await vm.reload() }
            }
            ForEach(OOGenre.allCases) { genre in
                filterChip(genre.rawValue, selected: vm.selectedGenre == genre.rawValue) {
                    vm.selectedGenre = genre.rawValue
                    Task { await vm.reload() }
                }
            }
            Spacer()
            Button {
                vm.popularOnly.toggle()
                Task { await vm.reload() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: vm.popularOnly ? "star.fill" : "star")
                        .font(.system(size: 12))
                    Text("Popular")
                        .font(.roonBody(12, weight: .medium))
                }
                .foregroundColor(vm.popularOnly ? .roonBase : .roonSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(vm.popularOnly ? Color.roonAccent : Color.roonElevated)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func filterChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.roonBody(12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .roonBase : .roonTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.roonAccent : Color.roonElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.works.isEmpty {
            Spacer()
            ProgressView().tint(.roonAccent)
            Spacer()
        } else if vm.works.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 44))
                    .foregroundColor(.roonTertiary)
                Text("No works found")
                    .font(.roonBody(14))
                    .foregroundColor(.roonTertiary)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(vm.works) { item in
                        NavigationLink {
                            OOWorkDetailView(work: item.work, composer: item.composer)
                        } label: {
                            RandomWorkCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // Load more when near end
                            if item.id == vm.works.last?.id && !vm.isLoading {
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                    if vm.isLoading && !vm.works.isEmpty {
                        ProgressView().tint(.roonAccent).padding()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Work card

struct RandomWorkCard: View {

    let item: OORandomWork
    @ObservedObject private var linker = LMSLibraryLinker.shared
    @State private var isInLibrary: Bool? = nil   // nil = not yet checked

    var body: some View {
        HStack(spacing: 14) {
            // Composer portrait
            AsyncImage(url: composerPortraitURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                default:
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.roonElevated)
                        Text(NameFormatting.initials(item.composer.complete_name))
                            .font(.roonTitle(20))
                            .foregroundColor(.roonAccent)
                    }
                    .frame(width: 68, height: 68)
                }
            }
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.work.title)
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.composer.complete_name)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let genre = item.work.genre, !genre.isEmpty {
                        Text(genre)
                            .font(.roonBody(10, weight: .medium))
                            .foregroundColor(.roonAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.roonAccent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    if let epoch = item.composer.epoch, !epoch.isEmpty {
                        Text(epoch)
                            .font(.roonBody(10))
                            .foregroundColor(epochColor(epoch))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(epochColor(epoch).opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if item.work.isPopular {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#d4a042"))
                    }
                }
            }

            Spacer(minLength: 4)

            // Library status indicator
            if isInLibrary == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Color.green.opacity(0.8))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(14)
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .task(id: item.id) { await checkLibrary() }
        .onChange(of: linker.linkedCount) { _, _ in
            // Re-check library status when the linker finishes a build pass.
            if linker.isInLibrary(workID: item.work.id) { isInLibrary = true }
        }
    }

    private var composerPortraitURL: URL? {
        guard let p = item.composer.portrait, !p.isEmpty else { return nil }
        return URL(string: p)
    }

    private func checkLibrary() async {
        // Fast path: O(1) linker lookup, no network call
        if linker.isInLibrary(workID: item.work.id) {
            isInLibrary = true
            return
        }
        // If the linker has run at least once, trust its "not found"
        if linker.linkedCount > 0 || linker.lastRebuilt != nil {
            isInLibrary = false
            return
        }
        // Linker cache is empty (first launch before any indexing).
        // Fall back to a single lightweight title search so the user gets
        // some library indicators while the background index is building.
        let term = "\(item.composer.complete_name) \(item.work.title)"
        if let albums = try? await LyrionAPI.shared.searchAlbums(term: term, count: 5) {
            isInLibrary = albums.contains { item.work.title.similarity($0.album) > 0.5 }
        } else {
            isInLibrary = false
        }
    }
}

// MARK: - ViewModel

@MainActor
final class RandomWorksViewModel: ObservableObject {

    @Published var works: [OORandomWork] = []
    @Published var isLoading: Bool = false

    var selectedGenre: String? = nil
    var popularOnly: Bool = false

    private var page: Int = 0
    private var reloadTask: Task<Void, Never>?

    func load() async {
        guard works.isEmpty else { return }
        await reload()
    }

    func reload() async {
        // Cancel any in-flight reload before starting a new one.
        // This prevents stale filter results overwriting fresh ones when
        // the user taps filter chips rapidly.
        reloadTask?.cancel()
        page = 0
        isLoading = true
        let genre   = selectedGenre
        let popular = popularOnly
        let task = Task {
            let fetched = (try? await OpenOpusService.shared.randomWorks(
                genre:       genre,
                popularWork: popular
            )) ?? []
            guard !Task.isCancelled else { return }
            self.works = fetched
            self.isLoading = false
        }
        reloadTask = task
        await task.value
    }

    func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        let more = (try? await OpenOpusService.shared.randomWorks(
            genre:       selectedGenre,
            popularWork: popularOnly
        )) ?? []
        // Deduplicate by work ID
        let existing = Set(works.map(\.id))
        works += more.filter { !existing.contains($0.id) }
        isLoading = false
    }
}
