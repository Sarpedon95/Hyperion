import SwiftUI

// MARK: - Composer Detail (OpenOpus)

struct ComposerDetailView: View {

    let composer: OOComposer
    @StateObject private var vm: ComposerDetailViewModel

    // Navigation state for library destination
    @State private var albumNavRequest: AlbumNavRequest? = nil
    @State private var pickerNavRequest: PickerNavRequest? = nil
    @State private var resolvingWorkID: String? = nil
    @State private var notFoundWorkID: String? = nil

    init(composer: OOComposer) {
        self.composer = composer
        _vm = StateObject(wrappedValue: ComposerDetailViewModel(composer: composer))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                portraitHeader
                bioDates
                genreFilter
                worksList
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(composer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                favouriteButton
            }
        }
        .task { await vm.load() }
        .navigationDestination(item: $albumNavRequest) { req in
            AlbumDetailView(album: req.album, scrollToTrackID: req.firstTrackID, autoPlay: req.autoPlay)
        }
        .navigationDestination(item: $pickerNavRequest) { req in
            WorkRecordingPickerView(
                workTitle: req.workTitle,
                composerName: req.composerName,
                entries: req.entries
            )
        }
    }

    private func resolveWork(_ work: OOWork) {
        guard resolvingWorkID == nil else { return }
        resolvingWorkID = work.id
        Task {
            let nav = await vm.resolveLibraryDestination(work: work, composer: composer)
            switch nav {
            case .singleAlbum(let album, let firstTrackID, let doAutoPlay):
                albumNavRequest = AlbumNavRequest(
                    album: album, firstTrackID: firstTrackID, autoPlay: doAutoPlay
                )
            case .picker(let entries):
                pickerNavRequest = PickerNavRequest(
                    workID: work.id,
                    workTitle: work.title,
                    composerName: composer.complete_name,
                    entries: entries
                )
            case .notFound:
                notFoundWorkID = work.id
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if notFoundWorkID == work.id { notFoundWorkID = nil }
                }
            }
            resolvingWorkID = nil
        }
    }

    // MARK: - Portrait header

    private var portraitHeader: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: portraitURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    ZStack {
                        Color.roonElevated
                        Text(NameFormatting.initials(composer.complete_name))
                            .font(.roonTitle(72))
                            .foregroundColor(.roonAccent)
                    }
                @unknown default:
                    Color.roonElevated
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .clipped()

            // Gradient scrim for legibility
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: Color.roonBase.opacity(0.85), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(composer.complete_name)
                    .font(.roonTitle(26))
                    .foregroundColor(.roonPrimary)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                if let epoch = composer.epoch, !epoch.isEmpty {
                    Text(epoch)
                        .font(.roonBody(14, weight: .semibold))
                        .foregroundColor(epochColor(epoch))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Dates

    @ViewBuilder
    private var bioDates: some View {
        let birth = composer.birth
        let death = composer.death
        if (birth != nil && !(birth?.isEmpty ?? true)) || (death != nil && !(death?.isEmpty ?? true)) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(.roonTertiary)
                Text(dateString(birth: birth, death: death))
                    .font(.roonBody(13))
                    .foregroundColor(.roonSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Genre filter

    @ViewBuilder
    private var genreFilter: some View {
        if !vm.genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    genreChip("All", selected: vm.selectedGenre == nil) {
                        vm.selectGenre(nil)
                    }
                    ForEach(vm.genres, id: \.self) { genre in
                        genreChip(genre, selected: vm.selectedGenre == genre) {
                            vm.selectGenre(genre)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            Divider().background(Color.roonBorder)
        }
    }

    private func genreChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.roonBody(12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .roonBase : .roonSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.roonAccent : Color.roonElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Works list

    @ViewBuilder
    private var worksList: some View {
        if vm.isLoading && vm.displayedWorks.isEmpty {
            ProgressView().tint(.roonAccent).padding(40)
        } else if vm.displayedWorks.isEmpty {
            Text("No works found")
                .font(.roonBody(14))
                .foregroundColor(.roonTertiary)
                .padding(40)
        } else {
            VStack(spacing: 0) {
                ForEach(vm.displayedWorks) { work in
                    Button {
                        resolveWork(work)
                    } label: {
                        OOWorkRow(
                            work: work,
                            composer: composer,
                            isNavigating: resolvingWorkID == work.id,
                            isNotFound: notFoundWorkID == work.id
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    Divider().background(Color.roonBorder).padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var favouriteButton: some View {
        Button {
            // Future: persist favourites
        } label: {
            Image(systemName: "heart")
                .font(.system(size: 17))
                .foregroundColor(.roonSecondary)
        }
    }

    // MARK: - Helpers

    private var portraitURL: URL? {
        guard let p = composer.portrait, !p.isEmpty else { return nil }
        return URL(string: p)
    }

    private func dateString(birth: String?, death: String?) -> String {
        let b = birth.map { String($0.prefix(4)) } ?? ""
        let d = death.map { String($0.prefix(4)) } ?? ""
        switch (b.isEmpty, d.isEmpty) {
        case (false, false): return "\(b) – \(d)"
        case (false, true):  return "b. \(b)"
        default:             return ""
        }
    }
}

// MARK: - Work row inside ComposerDetailView

struct OOWorkRow: View {

    let work: OOWork
    let composer: OOComposer
    var isNavigating: Bool = false
    var isNotFound: Bool = false

    @ObservedObject private var player = PlayerViewModel.shared
    @ObservedObject private var linker = LMSLibraryLinker.shared
    @State private var matchState: WorkMatchState = .idle

    enum WorkMatchState {
        case idle, searching, found(Int), notFound   // found(albumID)
    }

    private var storedCandidate: WorkRecordingCandidate? {
        linker.topCandidate(forWorkID: work.id)
    }

    // Catalogue number / key (subtitle) — shown only if not already in the title.
    private var catalogueHint: String? {
        guard let sub = work.subtitle, !sub.isEmpty else { return nil }
        let titleLower = work.title.lowercased()
        let subLower   = sub.lowercased()
        return titleLower.contains(subLower) ? nil : sub
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if work.isPopular {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.roonAccent)
                    }
                    Text(work.title)
                        .font(.roonBody(14, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if linker.isInLibrary(workID: work.id) {
                        Circle()
                            .fill(Color.green.opacity(0.8))
                            .frame(width: 5, height: 5)
                    }
                }
                if let hint = catalogueHint {
                    Text(hint)
                        .font(.roonBody(11))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
                if let genre = work.genre, !genre.isEmpty {
                    Text(genre)
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                }
            }

            Spacer()

            playControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var playControl: some View {
        if isNavigating {
            ProgressView().scaleEffect(0.75).tint(.roonAccent)
                .frame(width: 44, height: 44)
        } else if isNotFound {
            Text("Not found")
                .font(.roonBody(10))
                .foregroundColor(.roonTertiary)
                .frame(width: 60)
        } else {
            switch matchState {
            case .idle:
                Button { findAndPlay() } label: {
                    Image(systemName: storedCandidate != nil ? "play.circle.fill" : "play.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.roonAccent)
                }
                .buttonStyle(.plain)

            case .searching:
                ProgressView().scaleEffect(0.75).tint(.roonAccent)

            case .found(let albumID):
                Button { playAlbum(albumID: albumID) } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.roonAccent)
                }
                .buttonStyle(.plain)

            case .notFound:
                Text("Not in library")
                    .font(.roonBody(10))
                    .foregroundColor(.roonTertiary)
                    .frame(width: 60)
            }
        }
    }

    private func findAndPlay() {
        // Use stored candidate directly if available
        if let candidate = storedCandidate {
            playAlbum(albumID: candidate.lmsAlbumID)
            matchState = .found(candidate.lmsAlbumID)
            return
        }
        matchState = .searching
        Task {
            if let albumID = await fuzzyMatchAlbumID() {
                matchState = .found(albumID)
                playAlbum(albumID: albumID)
            } else {
                matchState = .notFound
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if case .notFound = matchState { matchState = .idle }
                }
            }
        }
    }

    private func playAlbum(albumID: Int) {
        Task {
            do {
                let tracks = try await LyrionAPI.shared.getTracksForAlbum(albumID: albumID)
                guard !tracks.isEmpty else { return }
                let groups = LyrionAPI.shared.groupTracksByWork(tracks)
                if groups.isEmpty {
                    player.playSingleTrack(tracks[0])
                } else {
                    player.playAlbum(groups)
                }
            } catch {
                linkerLog("OOWorkRow.playAlbum failed for albumID \(albumID): \(error)")
            }
        }
    }

    private func fuzzyMatchAlbumID() async -> Int? {
        let term = "\(composer.complete_name) \(work.title)"
        let albums: [Album]
        do {
            albums = try await LyrionAPI.shared.searchAlbums(term: term, count: 20)
        } catch {
            linkerLog("OOWorkRow.fuzzyMatchAlbumID search failed for '\(term)': \(error)")
            return nil
        }
        var best: Int? = nil
        var bestScore: Double = 0.45
        for album in albums {
            let titleScore    = work.title.similarity(album.album)
            let composerScore = composer.complete_name.similarity(
                album.composer ?? album.artist ?? ""
            )
            let combined  = titleScore * 0.7 + composerScore * 0.3
            let words     = work.title.lowercased().split(whereSeparator: \.isWhitespace)
            let lower     = album.album.lowercased()
            let wordHit   = words.isEmpty ? 0.0
                : Double(words.filter { lower.contains($0) }.count) / Double(words.count)
            let score = Swift.max(combined, wordHit * 0.8)
            if score > bestScore { bestScore = score; best = album.id }
        }
        return best
    }
}

// MARK: - ViewModel

@MainActor
final class ComposerDetailViewModel: ObservableObject {

    @Published var genres: [String] = []
    @Published var allWorks: [OOWork] = []
    @Published var isLoading: Bool = false
    @Published var selectedGenre: String? = nil

    var displayedWorks: [OOWork] {
        guard let g = selectedGenre else { return allWorks }
        return allWorks.filter { $0.genre?.caseInsensitiveCompare(g) == .orderedSame }
    }

    private let composer: OOComposer

    init(composer: OOComposer) { self.composer = composer }

    func load() async {
        guard allWorks.isEmpty else { return }
        isLoading = true
        async let fetchGenres = OpenOpusService.shared.genresForComposer(composer.id)
        async let fetchWorks  = OpenOpusService.shared.worksForComposer(composer.id)
        do { genres = try await fetchGenres }
        catch { linkerLog("ComposerDetailViewModel: genres fetch failed for \(composer.id): \(error)") }
        var works: [OOWork] = []
        do { works = try await fetchWorks }
        catch { linkerLog("ComposerDetailViewModel: works fetch failed for \(composer.id): \(error)") }
        works.sort { lhs, rhs in
            if lhs.isPopular != rhs.isPopular { return lhs.isPopular }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        allWorks = works
        isLoading = false
    }

    func selectGenre(_ genre: String?) {
        withAnimation(.easeInOut(duration: 0.15)) { selectedGenre = genre }
    }

    // MARK: - Library resolution

    func resolveLibraryDestination(work: OOWork, composer: OOComposer) async -> WorkLibraryNav {
        // Phase 1: use pre-indexed candidates from LMSLibraryLinker (highest quality data)
        let indexed = LMSLibraryLinker.shared.candidates(forWorkID: work.id)

        var entries: [WorkRecordingEntry] = []

        if !indexed.isEmpty {
            let cachedAlbums = LibraryViewModel.shared.albums
            for candidate in indexed {
                let album = cachedAlbums.first(where: { $0.id == candidate.lmsAlbumID })
                    ?? Album(
                        id:               candidate.lmsAlbumID,
                        album:            candidate.lmsAlbumName,
                        artist:           candidate.performerSummary,
                        year:             nil,
                        artwork_track_id: candidate.artworkTrackID,
                        composer:         composer.complete_name,
                        isClassical:      1
                    )
                entries.append(WorkRecordingEntry(
                    id:               candidate.lmsAlbumID,
                    album:            album,
                    firstTrackID:     candidate.lmsTrackIDs.first,
                    trackCount:       candidate.lmsTrackIDs.count,
                    performerSummary: candidate.performerSummary
                ))
            }
        } else {
            // Phase 2: live fuzzy search (same scoring as OOWorkRow.fuzzyMatchAlbumID)
            let term = "\(composer.complete_name) \(work.title)"
            let albums = (try? await LyrionAPI.shared.searchAlbums(term: term, count: 20)) ?? []
            let workWords = work.title.lowercased().split(whereSeparator: \.isWhitespace)

            for album in albums {
                let titleScore    = work.title.similarity(album.album)
                let composerScore = composer.complete_name.similarity(album.composer ?? album.artist ?? "")
                let combined      = titleScore * 0.7 + composerScore * 0.3
                let lower         = album.album.lowercased()
                let wordHit       = workWords.isEmpty ? 0.0
                    : Double(workWords.filter { lower.contains($0) }.count) / Double(workWords.count)
                let score = Swift.max(combined, wordHit * 0.8)
                guard score > 0.45 else { continue }

                entries.append(WorkRecordingEntry(
                    id:               album.id,
                    album:            album,
                    firstTrackID:     nil,
                    trackCount:       0,
                    performerSummary: album.artist
                ))
            }
        }

        // Deduplicate by album ID, preserving order
        var seen = Set<Int>()
        entries = entries.filter { seen.insert($0.id).inserted }

        switch entries.count {
        case 0:
            return .notFound
        case 1:
            let e = entries[0]
            // Single-track work → autoPlay so the user hears it immediately
            let singleTrack = e.trackCount == 1
            return .singleAlbum(album: e.album, firstTrackID: e.firstTrackID, autoPlay: singleTrack)
        default:
            return .picker(entries: entries)
        }
    }
}

// MARK: - Navigation model types

enum WorkLibraryNav {
    case singleAlbum(album: Album, firstTrackID: Int?, autoPlay: Bool)
    case picker(entries: [WorkRecordingEntry])
    case notFound
}

struct WorkRecordingEntry: Identifiable, Hashable {
    let id: Int               // lmsAlbumID — unique per recording
    let album: Album
    let firstTrackID: Int?    // scroll target inside AlbumDetailView
    let trackCount: Int       // 0 = unknown (fallback search path)
    let performerSummary: String?
}

struct AlbumNavRequest: Identifiable, Hashable {
    let album: Album
    let firstTrackID: Int?
    let autoPlay: Bool
    var id: Int { album.id }
}

struct PickerNavRequest: Identifiable, Hashable {
    let workID: String
    let workTitle: String
    let composerName: String
    let entries: [WorkRecordingEntry]
    var id: String { workID }
}

// MARK: - Recording picker ("Choose a recording")

struct WorkRecordingPickerView: View {

    let workTitle: String
    let composerName: String
    let entries: [WorkRecordingEntry]

    @State private var albumNavRequest: AlbumNavRequest? = nil
    @State private var selectedDecade: Int? = nil  // nil = All

    private var availableDecades: [Int] {
        var seen = Set<Int>()
        return entries.compactMap { e in
            guard let y = e.album.year, y > 0 else { return nil }
            let d = (y / 10) * 10
            return seen.insert(d).inserted ? d : nil
        }.sorted()
    }

    private var filteredEntries: [WorkRecordingEntry] {
        guard let d = selectedDecade else { return entries }
        return entries.filter {
            guard let y = $0.album.year, y > 0 else { return false }
            return (y / 10) * 10 == d
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if availableDecades.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        decadeChip("All", selected: selectedDecade == nil) { selectedDecade = nil }
                        ForEach(availableDecades, id: \.self) { d in
                            decadeChip("\(d)s", selected: selectedDecade == d) { selectedDecade = d }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color.roonBase)
                Divider().background(Color.roonBorder)
            }

            List {
                Section {
                    ForEach(filteredEntries) { entry in
                        Button {
                            albumNavRequest = AlbumNavRequest(
                                album:        entry.album,
                                firstTrackID: entry.firstTrackID,
                                autoPlay:     false
                            )
                        } label: {
                            RecordingPickerRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.roonSurface)
                        .listRowSeparatorTint(Color.roonBorder)
                    }
                } header: {
                    Text(composerName.uppercased())
                        .font(.roonBody(11, weight: .semibold))
                        .foregroundColor(.roonAccent)
                        .kerning(1.2)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(workTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $albumNavRequest) { req in
            AlbumDetailView(
                album:        req.album,
                scrollToTrackID: req.firstTrackID,
                autoPlay:     req.autoPlay
            )
        }
    }

    private func decadeChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.roonBody(12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .roonBase : .roonSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.roonAccent : Color.roonElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RecordingPickerRow: View {

    let entry: WorkRecordingEntry
    @ObservedObject private var annotations = RecordingAnnotationStore.shared
    @State private var showAnnotationSheet = false

    private var isHIP: Bool {
        HIPEnsembleClassifier.shared.isHIP(
            conductor: entry.album.conductor,
            band: entry.album.band,
            performerSummary: entry.performerSummary
        )
    }

    private var annotation: RecordingAnnotation? {
        annotations.annotation(forAlbumID: entry.album.id)
    }

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: entry.album.artwork_track_id, size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.album.album)
                        .font(.roonBody(15, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                    if isHIP {
                        Text("HIP")
                            .font(.roonBody(9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.roonAccent.opacity(0.85))
                            .clipShape(Capsule())
                    }
                }

                if let performer = entry.performerSummary ?? entry.album.artist,
                   !performer.isEmpty {
                    Text(performer)
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }

                if let r = annotation?.rating {
                    StarRatingView(rating: r)
                }

                if let year = entry.album.year, year > 0 {
                    Text(String(year))
                        .font(.roonBody(12))
                        .foregroundColor(.roonTertiary)
                }

                if let note = annotation?.notes, !note.isEmpty {
                    Text(note)
                        .font(.roonBody(11))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }

            Spacer()

            Button {
                showAnnotationSheet = true
            } label: {
                Image(systemName: annotation != nil ? "pencil.circle.fill" : "pencil.circle")
                    .font(.system(size: 20))
                    .foregroundColor(annotation != nil ? .roonAccent : .roonTertiary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showAnnotationSheet) {
            RecordingAnnotationSheet(albumID: entry.album.id, albumTitle: entry.album.album)
        }
        .contextMenu {
            Button { showAnnotationSheet = true } label: {
                Label("Add Note / Rating", systemImage: "pencil")
            }
        }
    }
}
