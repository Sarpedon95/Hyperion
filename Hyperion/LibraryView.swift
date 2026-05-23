import SwiftUI
import UIKit

// MARK: - Environment: scroll-to highlight (set by AlbumDetailView, read by MovementRowView)

private struct HighlightedTrackIDKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var highlightedTrackID: Int? {
        get { self[HighlightedTrackIDKey.self] }
        set { self[HighlightedTrackIDKey.self] = newValue }
    }
}

// MARK: - Library root

struct LibraryView: View {

    @Binding var path: NavigationPath

    init(path: Binding<NavigationPath> = .constant(NavigationPath())) {
        _path = path
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("My Library")
                        .font(.roonTitle(34))
                        .foregroundColor(.roonPrimary)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 24)

                    VStack(spacing: 0) {
                        NavigationLink(destination: SongListView()) {
                            LibraryMenuRow(icon: "music.note",               label: "Songs")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: LikedTracksView()) {
                            LibraryMenuRow(icon: "heart.fill",               label: "Liked Tracks")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: PlaylistListView()) {
                            LibraryMenuRow(icon: "music.note.list",          label: "Playlists")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: ServerPlaylistListView()) {
                            LibraryMenuRow(icon: "server.rack",              label: "Server Playlists")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: AlbumListView()) {
                            LibraryMenuRow(icon: "square.stack.fill",        label: "Albums")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: ArtistListView()) {
                            LibraryMenuRow(icon: "person.crop.circle.fill",  label: "Artists")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: GenreListView()) {
                            LibraryMenuRow(icon: "guitars.fill",             label: "Genres")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        // Composers / Works / Classical are intentionally absent
                        // from the Library tab. When classical mode is on they live
                        // in the dedicated Classical tab; when off they're hidden
                        // everywhere. Either way the Library tab stays non-classical.

                        NavigationLink(destination: HistoryView()) {
                            LibraryMenuRow(icon: "chart.bar.fill",            label: "History")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: StatsView()) {
                            LibraryMenuRow(icon: "chart.xyaxis.line",         label: "Listening Stats")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: JournalView()) {
                            LibraryMenuRow(icon: "book.closed.fill",           label: "Listening Journal")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: OfflineLibraryView()) {
                            LibraryMenuRow(icon: "wifi.slash",                label: "Offline Library")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: DownloadsView()) {
                            LibraryMenuRow(icon: "arrow.down.circle.fill",    label: "Downloads")
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .background(Color.roonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)

                    // MARK: - Streaming (admin only)
                    if UserSession.shared.isAdmin {
                        Text("STREAMING")
                            .font(.roonBody(13, weight: .semibold))
                            .foregroundColor(.roonSecondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 32)
                            .padding(.bottom, 12)

                        VStack(spacing: 0) {
                            NavigationLink(destination: StreamingFavoritesView(source: .qobuz)) {
                                StreamingLibraryRow(source: .qobuz, label: "Qobuz Favorites")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())

                            Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                            NavigationLink(destination: StreamingFavoritesView(source: .deezer)) {
                                StreamingLibraryRow(source: .deezer, label: "Deezer Favorites")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)
                    }

                    Spacer(minLength: 40)
                }
            }
            .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

// Library row for streaming sources. Visually matches LibraryMenuRow but
// swaps the system-icon tile for the source's coloured initial badge.
struct StreamingLibraryRow: View {
    let source: StreamSourceType
    let label: String

    private var color: Color {
        switch source {
        case .qobuz:  return Color(red: 0,     green: 0.706, blue: 0.847)
        case .deezer: return Color(red: 0.937, green: 0.329, blue: 0.4)
        case .local:  return .roonAccent
        }
    }

    private var initial: String {
        switch source {
        case .qobuz:  return "Q"
        case .deezer: return "D"
        case .local:  return "L"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.18))
                    .frame(width: 36, height: 36)
                Text(initial)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(color)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)

            Text(label)
                .font(.roonBody(17, weight: .medium))
                .foregroundColor(.roonPrimary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
                .padding(.trailing, 16)
        }
        .frame(height: 60)
        .contentShape(Rectangle())
    }
}

struct LibraryMenuRow: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.roonElevated)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.roonSecondary)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)

            Text(label)
                .font(.roonBody(17, weight: .medium))
                .foregroundColor(.roonPrimary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
                .padding(.trailing, 16)
        }
        .frame(height: 60)
        .contentShape(Rectangle())
    }
}

// MARK: - Composer list

struct ComposerListView: View {

    @ObservedObject private var library = LibraryViewModel.shared
    @State private var searchText: String = ""
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty
    @State private var epochFilter: OOEpoch = .all
    @State private var epochByName: [String: OOEpoch] = [:]
    @State private var isLoadingEpochs: Bool = false

    private var filtered: [Composer] {
        let base = searchNeedle.isEmpty
            ? library.composers
            : library.composers.filter { searchNeedle.matches($0.artist) }
        guard epochFilter != .all else { return base }
        return base.filter { epochByName[SearchTextNormalizer.folded($0.artist)] == epochFilter }
    }

    /// Epochs that actually appear in the current composer list (only show useful chips).
    private var availableEpochs: [OOEpoch] {
        guard !epochByName.isEmpty else { return [] }
        var seen = Set<OOEpoch>()
        for c in library.composers {
            if let e = epochByName[SearchTextNormalizer.folded(c.artist)] { seen.insert(e) }
        }
        return OOEpoch.allCases.filter { $0 != .all && seen.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !availableEpochs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([OOEpoch.all] + availableEpochs) { epoch in
                            EraChip(
                                label: epoch == .all ? "All" : epoch.rawValue,
                                isSelected: epochFilter == epoch
                            ) { epochFilter = epoch }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color.roonBase)
                Divider().background(Color.roonBorder)
            }

            List {
                ForEach(filtered) { composer in
                    NavigationLink {
                        WorkListView(composerID: composer.id, composerName: composer.artist)
                    } label: {
                        ComposerRowView(
                            composer: composer,
                            epoch: epochByName[SearchTextNormalizer.folded(composer.artist)]
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
            .overlay {
                if library.isLoadingComposers {
                    ProgressView().tint(.roonAccent)
                }
            }
        }
        .background(Color.roonBase)
        .searchable(text: $searchText, prompt: "Search composers")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle("Composers")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if library.composers.isEmpty { await library.loadComposers() }
        }
        .task {
            guard epochByName.isEmpty, !isLoadingEpochs else { return }
            isLoadingEpochs = true
            epochByName = await OOComposerCache.shared.epochByName()
            isLoadingEpochs = false
        }
    }
}

private struct EraChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { Haptics.light(); action() }) {
            Text(label)
                .font(.roonBody(13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .black : .roonSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.roonAccent : Color.roonElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ComposerRowView: View {
    let composer: Composer
    var epoch: OOEpoch? = nil

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.roonElevated)
                    .frame(width: 46, height: 46)
                Text(NameFormatting.initials(composer.artist))
                    .font(.roonTitle(16))
                    .foregroundColor(.roonAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(composer.artist)
                    .font(.roonBody(16, weight: .medium))
                    .foregroundColor(.roonPrimary)
                if let epoch {
                    Text(epoch.rawValue)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Work list

struct WorkListView: View {

    let composerID: Int?
    let composerName: String?

    @ObservedObject private var library = LibraryViewModel.shared
    @State private var searchText: String = ""
    @State private var works: [Work]   = []
    @State private var isLoading: Bool = true
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    private var filtered: [Work] {
        guard !searchNeedle.isEmpty else { return works }
        return works.filter {
            searchNeedle.matches($0.work) || searchNeedle.matches($0.composer ?? "")
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { work in
                NavigationLink {
                    WorkDetailView(work: work)
                } label: {
                    WorkRowView(work: work, showComposer: composerID == nil)
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
        .background(Color.roonBase)
        .searchable(text: $searchText, prompt: "Search works")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle(composerName ?? "Works")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay {
            if isLoading {
                ProgressView().tint(.roonAccent)
            } else if !searchText.isEmpty && filtered.isEmpty {
                Text("No results for \"\(searchText)\"")
                    .foregroundColor(.roonSecondary)
                    .font(.roonBody(15))
            } else if works.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No works found")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                }
            }
        }
        .task(id: composerID) {
            isLoading = true
            defer { isLoading = false }
            do {
                let loadedWorks = try await library.loadWorks(composerID: composerID)
                guard !Task.isCancelled else { return }
                works = loadedWorks
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                works = []
            }
        }
    }
}

struct WorkRowView: View {
    let work: Work
    let showComposer: Bool

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: work.artwork_track_id, size: 54)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(work.work)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                if showComposer, let composer = work.composer, !composer.isEmpty {
                    Text(composer)
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Work detail

struct WorkDetailView: View {

    let work: Work

    @ObservedObject private var library = LibraryViewModel.shared
    @ObservedObject private var player  = PlayerViewModel.shared
    @State private var tracks: [Track]       = []
    @State private var workGroup: WorkGroup? = nil
    @State private var isLoading: Bool       = true
    @State private var loadError: String?    = nil
    @State private var retryToken: Int       = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                CenteredArtworkHeader(
                    coverid:  work.artwork_track_id,
                    title:    work.work,
                    subtitle: work.composer
                )

                if !tracks.isEmpty {
                    playbackButtons
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)

                    Color.roonBorder.frame(height: 0.5)

                    WorkTrackList(tracks: tracks, workGroup: workGroup)

                    // All recordings of this work across the library, grouped by
                    // performance. Only meaningful for a real LMS work_id.
                    if work.work_id > 0 {
                        Color.roonBorder.frame(height: 0.5)
                        NavigationLink {
                            WorkPerformancesView(
                                workID: work.work_id,
                                workTitle: work.work,
                                initialTracks: tracks
                            )
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.roonElevated)
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "square.stack.3d.up")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.roonSecondary)
                                }
                                Text("All Performances")
                                    .font(.roonBody(16, weight: .medium))
                                    .foregroundColor(.roonPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.roonTertiary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isLoading {
                    ProgressView()
                        .tint(.roonAccent)
                        .padding(40)
                }

                if let error = loadError {
                    VStack(spacing: 12) {
                        Text(error)
                            .font(.roonBody(14))
                            .foregroundColor(.roonSecondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Haptics.light()
                            retryToken += 1
                        }
                        .font(.roonBody(14, weight: .semibold))
                        .foregroundColor(.roonAccent)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // BUG FIX: Using work.work_id as the task id is unsafe for fabricated Work
        // objects from search results where work_id == 0 — all such works share the
        // same task id and the task only fires once for all of them. Use the stable
        // String id (which includes work title + composer for fabricated works) so
        // the task re-fires correctly on every distinct work.
        .task(id: "\(work.id)-\(retryToken)") {
            isLoading = true
            loadError = nil
            // BUG FIX: defer ensures isLoading is always cleared, even when the task
            // is cancelled mid-flight (e.g. user navigates away and immediately back
            // to the same work, which keeps the same task id and doesn't re-fire).
            // Without defer, a cancellation left isLoading = true permanently,
            // showing a spinner forever with no data.
            defer { isLoading = false }
            do {
                let loaded: [Track]
                if work.work_id > 0 {
                    loaded = try await library.getTracksForWork(work.work_id)
                } else if let albumIDString = work.album_id,
                          let albumID = Int(albumIDString) {
                    let groups = try await library.getWorkGroupsForAlbum(albumID)
                    loaded = groups.first {
                        $0.workTitle.localizedCaseInsensitiveCompare(work.work) == .orderedSame
                    }?.tracks ?? []
                } else {
                    loaded = []
                }

                guard !Task.isCancelled else { return }
                tracks    = loaded
                workGroup = loaded.isEmpty ? nil : WorkGroup(
                    id:        work.work_id > 0 ? work.work_id : (loaded.first?.id ?? 0),
                    workTitle: work.work,
                    composer:  work.composer,
                    tracks:    loaded,
                    coverid:   loaded.first?.coverid
                )
                if loaded.isEmpty {
                    loadError = "No playable tracks were found for this work."
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private var playbackButtons: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.medium()
                if let wg = workGroup {
                    player.playWork(wg)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Play")
                        .font(.roonBody(16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.roonAccent)
                .clipShape(RoundedRectangle(cornerRadius: 25))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play work")

            Button {
                Haptics.light()
                if let wg = workGroup {
                    player.addWorkToQueue(wg)
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.roonBorder, lineWidth: 1.5)
                        .frame(width: 50, height: 50)
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.roonSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to queue")
        }
    }
}

// MARK: - Centred artwork header (used in WorkDetailView and AlbumDetailView)

struct CenteredArtworkHeader: View {
    let coverid: String?
    let title: String
    let subtitle: String?
    var year: Int? = nil
    var subtitleAction: (() -> Void)? = nil
    var performerLine: String? = nil  // conductor · orchestra or performer credit

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let side = min(geo.size.width * 0.42, 220.0)
                HStack {
                    Spacer(minLength: 0)
                    ArtworkView(coverid: coverid, size: side)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 10)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 80)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Text(title)
                .font(.roonTitle(22))
                .foregroundColor(.roonPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)

            if let subtitle, !subtitle.isEmpty {
                if let subtitleAction {
                    Button(action: subtitleAction) {
                        Text(subtitle)
                            .font(.roonBody(15, weight: .medium))
                            .foregroundColor(.roonAccent)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 24)
                            .padding(.bottom, performerLine != nil ? 2 : (year != nil ? 2 : 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(subtitle)
                        .font(.roonBody(15, weight: .medium))
                        .foregroundColor(.roonAccent)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                        .padding(.bottom, performerLine != nil ? 2 : (year != nil ? 2 : 8))
                }
            }

            if let performerLine, !performerLine.isEmpty {
                Text(performerLine)
                    .font(.roonBody(13))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.bottom, year != nil ? 2 : 8)
            }

            if let year, year > 0 {
                Text("\(year)")
                    .font(.roonBody(13))
                    .foregroundColor(.roonTertiary)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Work track list

struct WorkTrackList: View {

    let tracks: [Track]
    let workGroup: WorkGroup?
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                MovementRowView(
                    track:    track,
                    index:    index,
                    isActive: player.currentTrack?.id == track.id
                ) {
                    Haptics.light()
                    if let wg = workGroup {
                        player.playWork(wg, startingAt: index)
                    }
                }
                .id("track-\(track.id)")
                if index < tracks.count - 1 {
                    Color.roonBorder.frame(height: 0.5)
                        .padding(.leading, 54)
                }
            }
        }
    }
}

struct MovementRowView: View {
    let track: Track
    let index: Int
    let isActive: Bool
    var showPerformer: Bool = false
    let onTap: () -> Void
    @ObservedObject private var likedTracks = LikedTracksStore.shared
    @State private var showingAddToPlaylist = false
    @State private var showingTrackActions = false
    @State private var navigateToAlbum: Album? = nil
    @State private var navigateToArtist: Artist? = nil
    @Environment(\.highlightedTrackID) private var highlightedTrackID

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Active waveform indicator — small, left-aligned
                if isActive {
                    Group {
                        if #available(iOS 17.0, *) {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: true)
                        } else {
                            Image(systemName: "waveform")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.roonAccent)
                    .frame(width: 16)
                    .padding(.leading, 16)
                } else {
                    Color.clear
                        .frame(width: 16)
                        .padding(.leading, 16)
                }

                // Title + performed by
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.roonBody(16, weight: .medium))
                        .foregroundColor(isActive ? .roonAccent : .roonPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    let performer = track.trackartist ?? track.albumartist
                    if let performer, !performer.isEmpty {
                        Text("Performed by \(performer)")
                            .font(.roonBody(13, weight: .regular))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // "…" context button
                Button {
                    Haptics.light()
                    showingTrackActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.roonTertiary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More options for \(track.title)")
                .padding(.trailing, 8)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(track.title, isPresented: $showingTrackActions, titleVisibility: .visible) {
            Button("Play Now") {
                onTap()
            }
            Button("Play Next") {
                PlayerViewModel.shared.playNext([track])
            }
            Button("Add to Queue") {
                PlayerViewModel.shared.addTracksToQueue([track])
            }
            Button("Add to Playlist") {
                showingAddToPlaylist = true
            }
            if DownloadManager.shared.isDownloaded(trackID: track.id) {
                Button("Remove Download", role: .destructive) {
                    if let d = DownloadManager.shared.downloadedTracks.first(where: { $0.id == track.id }) {
                        DownloadManager.shared.removeDownload(d)
                    }
                }
            } else {
                Button("Download") {
                    DownloadManager.shared.download(track)
                }
            }
            Button(likedTracks.isLiked(track) ? "Unlike" : "Like") {
                likedTracks.toggle(track)
            }
            if let albumID = track.albumID,
               let album = LibraryViewModel.shared.albums.first(where: { $0.id == albumID }) {
                Button("Go to Album") { navigateToAlbum = album }
            }
            let artistName = track.trackartist ?? track.albumartist ?? ""
            if !artistName.isEmpty {
                Button("Go to Artist") {
                    navigateToArtist = LibraryViewModel.shared.artists.first { $0.name == artistName }
                        ?? Artist(id: 0, name: artistName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddToPlaylistSheet(tracks: [track])
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .sheet(item: $navigateToAlbum) { album in
            NavigationStack { AlbumDetailView(album: album) }
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .sheet(item: $navigateToArtist) { artist in
            NavigationStack { ArtistDetailView(artist: artist) }
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .background(highlightedTrackID == track.id ? Color.roonAccent.opacity(0.13) : Color.clear)
        .animation(.easeOut(duration: 0.3), value: highlightedTrackID)
    }
}

// MARK: - Album list

struct AlbumListView: View {

    @ObservedObject private var library = LibraryViewModel.shared

    @AppStorage(ClassicalMode.defaultsKey) private var classicalModeEnabled: Bool = true

    @State private var sortOrder: AlbumSortOrder = {
        let saved = UserDefaults.standard.string(forKey: "hyperion.library.albumSortOrder") ?? ""
        return AlbumSortOrder(rawValue: saved) ?? .album
    }()
    @State private var showSortPicker: Bool = false
    @State private var searchText: String = ""
    /// Tracks the measured scroll-view width so we can derive cellWidth without
    /// using the deprecated UIScreen.main.bounds API (incorrect on Stage Manager
    /// and multi-window iPad). Updated by onGeometryChange on iOS 17+.
    @State private var containerWidth: CGFloat = 390

    // Active filters
    @State private var filterClassicalOnly: Bool = false
    @State private var filterDecade: Int? = nil      // e.g. 1990 means 1990–1999
    @State private var showDecadePicker: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    /// 2 columns × 16 spacing + 16+16 horizontal padding = 48 fixed overhead.
    private var cellWidth: CGFloat {
        max(100, (containerWidth - 48) / 2)
    }

    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    private var availableDecades: [Int] {
        let years = library.albums.compactMap(\.year).filter { $0 > 1000 }
        let decades = Set(years.map { ($0 / 10) * 10 })
        return decades.sorted()
    }

    private var displayedAlbums: [Album] {
        var albums = library.albums
        // Hide purely-classical albums entirely when classical mode is off.
        if !classicalModeEnabled {
            albums = albums.filter { !$0.looksClassical }
        }
        if !searchNeedle.isEmpty {
            albums = albums.filter {
                searchNeedle.matches($0.album) ||
                searchNeedle.matches($0.artist ?? "") ||
                searchNeedle.matches($0.composer ?? "")
            }
        }
        if filterClassicalOnly {
            albums = albums.filter { ($0.isClassical ?? 0) != 0 }
        }
        if let decade = filterDecade {
            albums = albums.filter {
                guard let y = $0.year, y > 0 else { return false }
                return (y / 10) * 10 == decade
            }
        }
        return albums
    }

    private var hasActiveFilter: Bool { filterClassicalOnly || filterDecade != nil }

    var body: some View {
        ScrollView {
            // Filter/sort toolbar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Sort picker
                    filterChip(
                        label: sortOrder.rawValue,
                        icon: "arrow.up.arrow.down",
                        active: false
                    ) { showSortPicker = true }

                    // Classical filter
                    filterChip(
                        label: "Classical",
                        icon: "music.quarternote.3",
                        active: filterClassicalOnly
                    ) {
                        filterClassicalOnly.toggle()
                        Haptics.light()
                    }

                    // Decade filter
                    filterChip(
                        label: filterDecade.map { "\($0)s" } ?? "Decade",
                        icon: "calendar",
                        active: filterDecade != nil
                    ) { showDecadePicker = true }

                    // Clear filters
                    if hasActiveFilter {
                        Button {
                            Haptics.light()
                            filterClassicalOnly = false
                            filterDecade = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundColor(.roonTertiary)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }

                    Spacer(minLength: 8)

                    if library.isLoadingAlbums && library.albums.isEmpty {
                        ProgressView()
                            .tint(.roonAccent)
                            .scaleEffect(0.8)
                    }
                }
                .padding(.horizontal, 16)
                .animation(.easeInOut(duration: 0.2), value: hasActiveFilter)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            if displayedAlbums.isEmpty && !library.isLoadingAlbums {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 44))
                        .foregroundColor(.roonTertiary)
                    Text(searchText.isEmpty ? "No albums" : "No results for \"\(searchText)\"")
                        .font(.roonTitle(17))
                        .foregroundColor(.roonSecondary)
                }
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(displayedAlbums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            AlbumGridCell(album: album, cellWidth: cellWidth)
                        }
                        .buttonStyle(.plain)
                        // Prefetch album tracks on press-down so they're warm when the
                        // detail view opens. The cache deduplicates concurrent requests.
                        .simultaneousGesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                Task { try? await library.getTracksForAlbum(album.id) }
                            }
                        )
                        .onAppear {
                            // Pagination trigger: load next page when near the end.
                            // Guard the index access — library.albums can shrink
                            // between the time the cell appears and this closure fires
                            // (e.g. after a sort change that resets the array), which
                            // would cause an index-out-of-bounds crash.
                            guard searchText.isEmpty, !library.albums.isEmpty else { return }
                            let threshold = max(0, library.albums.count - 6)
                            guard library.albums.indices.contains(threshold) else { return }
                            if album.id == library.albums[threshold].id {
                                Task { await library.loadAlbums(sort: sortOrder) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)

                if library.isLoadingAlbums && !library.albums.isEmpty && searchText.isEmpty {
                    ProgressView()
                        .tint(.roonAccent)
                        .padding(.vertical, 18)
                }

                Spacer(minLength: 16)
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if width > 0 { containerWidth = width }
        }
        .searchable(text: $searchText, prompt: "Filter albums")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog("Sort Albums", isPresented: $showSortPicker, titleVisibility: .visible) {
            ForEach(AlbumSortOrder.allCases) { order in
                Button(order.rawValue) {
                    guard order != sortOrder else { return }
                    sortOrder = order
                    UserDefaults.standard.set(order.rawValue, forKey: "hyperion.library.albumSortOrder")
                    Task { await library.loadAlbums(reset: true, sort: order) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Filter by Decade", isPresented: $showDecadePicker, titleVisibility: .visible) {
            if filterDecade != nil {
                Button("All Decades") {
                    Haptics.light()
                    filterDecade = nil
                }
            }
            ForEach(availableDecades, id: \.self) { decade in
                Button("\(decade)s") {
                    Haptics.light()
                    filterDecade = decade
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            if library.albums.isEmpty { await library.loadAlbums(sort: sortOrder) }
        }
        .refreshable {
            await library.loadAlbums(reset: true, sort: sortOrder)
        }
    }

    @ViewBuilder
    private func filterChip(label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.roonBody(13, weight: .semibold))
            }
            .foregroundColor(active ? .white : .roonPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? Color.roonAccent : Color.roonSurface)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(active ? Color.clear : Color.roonBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct AlbumGridCell: View {
    let album: Album
    /// Pass the computed cell width in from the grid so we avoid a
    /// GeometryReader inside every LazyVGrid cell, which causes an extra
    /// layout pass per-cell and defeats the lazy rendering optimisation.
    var cellWidth: CGFloat = 160

    @State private var showAddToPlaylist = false
    @State private var playlistTracks: [Track] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(coverid: album.artwork_track_id, size: cellWidth)
                .frame(width: cellWidth, height: cellWidth)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.album)
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                if let artist = album.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("Play Now", systemImage: "play.fill") {
                Task {
                    let groups = (try? await LibraryViewModel.shared.getWorkGroupsForAlbum(album.id)) ?? []
                    guard !groups.isEmpty else { return }
                    await MainActor.run { PlayerViewModel.shared.playAlbum(groups) }
                }
            }
            Button("Play Next", systemImage: "text.insert") {
                Task {
                    let tracks = (try? await LibraryViewModel.shared.getTracksForAlbum(album.id)) ?? []
                    await MainActor.run { PlayerViewModel.shared.playNext(tracks) }
                }
            }
            Button("Add to Queue", systemImage: "text.badge.plus") {
                Task {
                    let groups = (try? await LibraryViewModel.shared.getWorkGroupsForAlbum(album.id)) ?? []
                    await MainActor.run { PlayerViewModel.shared.addWorkGroupsToQueue(groups) }
                }
            }
            Button("Start Radio", systemImage: "antenna.radiowaves.left.and.right") {
                Task {
                    let groups = (try? await LibraryViewModel.shared.getWorkGroupsForAlbum(album.id)) ?? []
                    guard let seed = groups.first?.tracks.first else { return }
                    await MainActor.run {
                        PlayerViewModel.shared.startRadio(seed: seed)
                    }
                }
            }
            Button("Add to Playlist", systemImage: "music.note.list") {
                Task {
                    let tracks = (try? await LibraryViewModel.shared.getTracksForAlbum(album.id)) ?? []
                    await MainActor.run {
                        playlistTracks = tracks
                        if !tracks.isEmpty { showAddToPlaylist = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(tracks: playlistTracks)
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
    }
}

// MARK: - Album list row (used in search results)

struct AlbumListRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: album.artwork_track_id, size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(album.album)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                if let artist = album.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
    }
}

struct ArtistAlbumGridCard: View {
    let album: Album

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(coverid: album.artwork_track_id, size: geo.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                Text(album.album)
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                if let year = album.year, year > 0 {
                    Text(String(year))
                        .font(.roonBody(11))
                        .foregroundColor(.roonSecondary)
                }
            }
        }
        .aspectRatio(0.75, contentMode: .fit)
    }
}

// MARK: - Album detail (with Tracks / Info / Credits tabs)

struct AlbumDetailView: View {

    let album: Album
    var scrollToTrackID: Int? = nil
    var autoPlay: Bool = false

    @ObservedObject private var library     = LibraryViewModel.shared
    @ObservedObject private var player      = PlayerViewModel.shared
    @ObservedObject private var annotations = RecordingAnnotationStore.shared
    @State private var workGroups: [WorkGroup] = []
    @State private var isLoading: Bool         = true
    @State private var loadError: String?      = nil
    @State private var retryToken: Int         = 0
    @State private var selectedTab: AlbumTab   = .tracks
    @State private var showArtistDetail: Bool  = false
    @State private var albumMetadata: MetadataResult? = nil
    @State private var albumMetadataLoading: Bool = false
    @State private var highlightedTrackID: Int? = nil
    @State private var showAnnotationSheet: Bool = false

    private var albumArtist: Artist? {
        guard let name = album.artist ?? album.composer, !name.isEmpty else { return nil }
        return library.artists.first { $0.name == name }
            ?? Artist(id: 0, name: name)
    }

    private var albumPerformerLine: String? {
        let c = album.conductor.flatMap { $0.isEmpty ? nil : $0 }
        let b = album.band.flatMap      { $0.isEmpty ? nil : $0 }
        switch (c, b) {
        case let (c?, b?): return "\(c) · \(b)"
        case let (c?, nil): return c
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    enum AlbumTab: String, CaseIterable {
        case tracks  = "TRACKS"
        case info    = "INFO"
        case credits = "CREDITS"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Header: artwork + title + artist + year + conductor/orchestra
                    CenteredArtworkHeader(
                        coverid:        album.artwork_track_id,
                        title:          album.album,
                        subtitle:       album.artist ?? album.composer,
                        year:           album.year,
                        subtitleAction: albumArtist != nil ? { showArtistDetail = true } : nil,
                        performerLine:  albumPerformerLine
                    )

                    // Recording annotation (rating + note preview)
                    if let ann = annotations.annotation(forAlbumID: album.id) {
                        Button { showAnnotationSheet = true } label: {
                            HStack(spacing: 10) {
                                if let r = ann.rating { StarRatingView(rating: r) }
                                if let note = ann.notes, !note.isEmpty {
                                    Text(note)
                                        .font(.roonBody(12))
                                        .foregroundColor(.roonSecondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundColor(.roonTertiary)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }

                    // Play Now / Add buttons
                    albumPlaybackButtons
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)

                    // MARK: Tab bar (Tracks / Info / Credits)
                    AlbumTabBar(selected: $selectedTab)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    Color.roonBorder.frame(height: 0.5)

                    // MARK: Tab content
                    switch selectedTab {
                    case .tracks:
                        tracksContent
                    case .info:
                        AlbumInfoPanel(album: album, workGroups: workGroups, metadata: albumMetadata, metadataLoading: albumMetadataLoading)
                    case .credits:
                        creditsContent
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
            .onChange(of: workGroups) { _, groups in
                guard let trackID = scrollToTrackID, !groups.isEmpty else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("track-\(trackID)", anchor: .top)
                    }
                    highlightedTrackID = trackID
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    withAnimation(.easeOut(duration: 0.4)) { highlightedTrackID = nil }
                }
            }
        }
        .environment(\.highlightedTrackID, highlightedTrackID)
        .background(Color.roonBase.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAnnotationSheet = true
                } label: {
                    Image(systemName: annotations.annotation(forAlbumID: album.id) != nil
                          ? "pencil.circle.fill" : "pencil.circle")
                        .font(.system(size: 17))
                        .foregroundColor(.roonSecondary)
                }
                .accessibilityLabel("Add note or rating")
            }
        }
        .sheet(isPresented: $showAnnotationSheet) {
            RecordingAnnotationSheet(albumID: album.id, albumTitle: album.album)
        }
        .navigationDestination(isPresented: $showArtistDetail) {
            if let artist = albumArtist { ArtistDetailView(artist: artist) }
        }
        .task(id: "\(album.id)-\(retryToken)") {
            isLoading = true
            loadError = nil
            workGroups = []
            albumMetadata = nil
            albumMetadataLoading = false
            highlightedTrackID = nil
            defer { isLoading = false }

            do {
                let groups = try await library.getWorkGroupsForAlbum(album.id)
                guard !Task.isCancelled else { return }
                workGroups = groups
                if autoPlay, let firstGroup = groups.first, !firstGroup.tracks.isEmpty {
                    player.playWork(firstGroup, startingAt: 0)
                }
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
            }

            // Fetch enriched metadata after tracks load
            let artistName = album.artist ?? album.composer ?? ""
            guard !artistName.isEmpty else { return }
            albumMetadataLoading = true
            albumMetadata = await MetadataService.shared.fetch(
                artist: artistName,
                album: album.album,
                track: nil
            )
            albumMetadataLoading = false
        }
    }

    @ViewBuilder
    private var tracksContent: some View {
        if isLoading {
            ProgressView().tint(.roonAccent).padding(40)
        } else if let error = loadError {
            VStack(spacing: 12) {
                Text(error)
                    .font(.roonBody(14))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Haptics.light()
                    retryToken += 1
                }
                .font(.roonBody(14, weight: .semibold))
                .foregroundColor(.roonAccent)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        } else if workGroups.isEmpty {
            Text("No playable tracks were found for this album.")
                .font(.roonBody(14))
                .foregroundColor(.roonSecondary)
                .multilineTextAlignment(.center)
                .padding(32)
                .frame(maxWidth: .infinity)
        } else {
            if workGroups.count == 1, let group = workGroups.first, group.isFlatFallbackGroup {
                WorkTrackList(tracks: group.tracks, workGroup: group)
            } else {
                ForEach(workGroups) { group in
                    WorkGroupSectionView(group: group, showPerformer: true)
                }
            }
            Spacer(minLength: 80)
        }
    }

    @ViewBuilder
    private var creditsContent: some View {
        let performers = uniquePerformers(from: workGroups)
        if isLoading {
            ProgressView().tint(.roonAccent).padding(40)
        } else if performers.isEmpty {
            Text("No performer credits available.")
                .font(.roonBody(14))
                .foregroundColor(.roonSecondary)
                .multilineTextAlignment(.center)
                .padding(32)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(performers.enumerated()), id: \.element) { index, performer in
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.roonElevated)
                                .frame(width: 38, height: 38)
                            Text(NameFormatting.initials(performer))
                                .font(.roonTitle(12))
                                .foregroundColor(.roonAccent)
                        }
                        Text(performer)
                            .font(.roonBody(15, weight: .medium))
                            .foregroundColor(.roonPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if index < performers.count - 1 {
                        Color.roonBorder.frame(height: 0.5).padding(.leading, 68)
                    }
                }
            }
            .background(Color.roonSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            Spacer(minLength: 80)
        }
    }

    private func uniquePerformers(from workGroups: [WorkGroup]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for group in workGroups {
            for track in group.tracks {
                if let artist = track.trackartist ?? track.albumartist, !artist.isEmpty {
                    if seen.insert(artist).inserted { result.append(artist) }
                }
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var albumPlaybackButtons: some View {
        HStack(spacing: 12) {
            // Play Now — muted indigo/purple pill (Roon Arc style)
            Button {
                Haptics.medium()
                guard !workGroups.isEmpty else { return }
                player.playAlbum(workGroups)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Play Now")
                        .font(.roonBody(15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.roonAccent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(workGroups.isEmpty)

            // Like / heart circle
            AlbumLikeButton(workGroups: workGroups)

            // Add to queue circle
            Button {
                Haptics.light()
                player.addWorkGroupsToQueue(workGroups)
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.roonBorder, lineWidth: 1.5)
                        .frame(width: 46, height: 46)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.roonSecondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(workGroups.isEmpty)
        }
    }
}

// MARK: - Album tab bar

struct AlbumTabBar: View {
    @Binding var selected: AlbumDetailView.AlbumTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AlbumDetailView.AlbumTab.allCases, id: \.self) { tab in
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.18)) { selected = tab }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selected == tab ? .semibold : .medium,
                                          design: .default))
                            .foregroundColor(selected == tab ? .roonPrimary : .roonTertiary)
                            .kerning(1.0)
                            .textCase(.uppercase)

                        // Short coral underline on selected tab only
                        Capsule()
                            .fill(selected == tab ? Color.roonAccent : Color.clear)
                            .frame(width: selected == tab ? 24 : 0, height: 2)
                            .animation(.easeInOut(duration: 0.18), value: selected)
                    }
                    .frame(height: 44)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Album like button (hearts all tracks in the album)

private struct AlbumLikeButton: View {
    let workGroups: [WorkGroup]
    @ObservedObject private var likedTracks = LikedTracksStore.shared

    private var allTracks: [Track] { workGroups.flatMap(\.tracks) }

    private var isAllLiked: Bool {
        !allTracks.isEmpty && allTracks.allSatisfy { likedTracks.isLiked($0) }
    }

    var body: some View {
        Button {
            Haptics.light()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
                if isAllLiked {
                    allTracks.forEach { likedTracks.unlike($0) }
                } else {
                    allTracks.forEach { if !likedTracks.isLiked($0) { likedTracks.like($0) } }
                }
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.roonBorder, lineWidth: 1.5)
                    .frame(width: 46, height: 46)
                Image(systemName: isAllLiked ? "heart.fill" : "heart")
                    .font(.system(size: 18))
                    .foregroundColor(isAllLiked ? .red : .roonSecondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(allTracks.isEmpty)
    }
}

// MARK: - Album info panel

struct AlbumInfoPanel: View {
    let album: Album
    let workGroups: [WorkGroup]
    var metadata: MetadataResult? = nil
    var metadataLoading: Bool = false
    @State private var reviewExpanded: Bool = false

    private var totalDuration: Double {
        workGroups.reduce(0) { $0 + $1.totalDuration }
    }

    private var trackCount: Int {
        workGroups.reduce(0) { $0 + $1.tracks.count }
    }

    private var formatLabel: String? {
        // Infer format from the first track URL
        guard let firstTrack = workGroups.first?.tracks.first,
              let rawURL = firstTrack.url, !rawURL.isEmpty else { return nil }
        let ext: String
        if let u = URL(string: rawURL), !u.pathExtension.isEmpty {
            ext = u.pathExtension.uppercased()
        } else {
            ext = (rawURL as NSString).pathExtension.uppercased()
        }
        return ext.isEmpty ? nil : ext
    }

    private var shouldShowClassicalBadge: Bool {
        album.isClassical == 1 ||
        album.composer != nil ||
        workGroups.contains { $0.composer != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Genre / format badge row
            HStack(spacing: 8) {
                if let fmt = formatLabel {
                    InfoBadge(text: fmt, color: .roonAccent)
                }
                if shouldShowClassicalBadge {
                    InfoBadge(text: "CLASSICAL", color: .roonTertiary)
                }
                if let dr = album.dynamicRange, dr > 0 {
                    InfoBadge(text: "DR\(dr)", color: .roonSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Color.roonBorder.frame(height: 0.5)

            // Metadata rows
            Group {
                if let year = album.year, year > 0 {
                    AlbumInfoRow(label: "Year", value: "\(year)")
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                }

                if let conductor = album.conductor, !conductor.isEmpty {
                    AlbumInfoRow(label: "Conductor", value: conductor)
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                }

                if let band = album.band, !band.isEmpty {
                    AlbumInfoRow(label: "Orchestra", value: band)
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                }

                if let artist = album.artist, !artist.isEmpty {
                    AlbumInfoRow(label: "Artist", value: artist)
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                }

                if let composer = album.composer, !composer.isEmpty {
                    AlbumInfoRow(label: "Composer", value: composer)
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                }

                AlbumInfoRow(label: "Tracks", value: "\(trackCount)")
                Color.roonBorder.frame(height: 0.5).padding(.leading, 20)

                AlbumInfoRow(label: "Works", value: "\(workGroups.count)")
                Color.roonBorder.frame(height: 0.5).padding(.leading, 20)

                AlbumInfoRow(label: "Duration", value: formatTotalDuration(totalDuration))

                if let fmt = formatLabel {
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                    AlbumInfoRow(label: "Format", value: fmt)
                }

                // Metadata-enriched fields
                if let year = metadata?.albumReleaseYear, !year.isEmpty {
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                    AlbumInfoRow(label: "Release", value: year)
                }
                if let label = metadata?.albumLabel, !label.isEmpty {
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                    AlbumInfoRow(label: "Label", value: label)
                }
                if let genre = metadata?.albumGenre, !genre.isEmpty {
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 20)
                    AlbumInfoRow(label: "Genre", value: genre.capitalized)
                }
            }

            // Tags from metadata
            if metadataLoading {
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.roonElevated)
                            .frame(width: 60, height: 24)
                            .redacted(reason: .placeholder)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            } else if let tags = metadata?.tags, !tags.isEmpty {
                MetadataTagsRow(tags: tags).padding(.top, 16)
            }

            // Album review
            if let review = metadata?.albumReview, !review.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Album Notes")
                        .font(.roonTitle(16))
                        .foregroundColor(.roonPrimary)
                        .padding(.horizontal, 20)
                    Text(review)
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(reviewExpanded ? nil : 4)
                        .padding(.horizontal, 20)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { reviewExpanded.toggle() }
                    } label: {
                        Text(reviewExpanded ? "Show less" : "Read more")
                            .font(.roonBody(12, weight: .semibold))
                            .foregroundColor(.roonAccent)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }
                .padding(.top, 16)
            }

            // Source badge
            if let source = metadata?.source {
                HStack {
                    Spacer()
                    Text("via \(source.displayName)")
                        .font(.roonBody(10))
                        .foregroundColor(.roonTertiary)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 8)
            }

            Spacer(minLength: 80)
        }
    }

    private func formatTotalDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total   = Int(seconds)
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}

private struct InfoBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.roonBody(11, weight: .semibold))
            .foregroundColor(color)
            .kerning(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct AlbumInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.roonBody(14))
                .foregroundColor(.roonTertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.roonBody(14, weight: .medium))
                .foregroundColor(.roonPrimary)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Work group section inside album detail (Tracks tab)

struct WorkGroupSectionView: View {
    let group: WorkGroup
    var showPerformer: Bool = false
    @ObservedObject private var player = PlayerViewModel.shared
    @State private var isCollapsed: Bool = false
    @State private var showingAddToPlaylist: Bool = false
    @State private var showingWorkCorrection: Bool = false

    private var sourceLabel: String {
        if group.tracks.contains(where: { ($0.work ?? "").isEmpty == false }) {
            return "Local work tag"
        }
        return "Inferred grouping"
    }

    private var performerLine: String {
        var parts: [String] = []
        if let c = group.composer?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            parts.append(c)
        }
        if let ta = group.tracks.first?.trackartist?.trimmingCharacters(in: .whitespaces),
           !ta.isEmpty, ta != group.composer {
            parts.append(ta)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header — Roon Arc classical style: bold title + year + performer line
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    // Work title + year inline
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(group.workTitle)
                            .font(.system(size: 17, weight: .bold, design: .default))
                            .foregroundColor(.roonPrimary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let year = group.tracks.compactMap(\.year).first, year > 0 {
                            Text("\(year)")
                                .font(.roonBody(13))
                                .foregroundColor(.roonTertiary)
                                .lineLimit(1)
                        }
                    }

                    // Composer / performer summary line
                    if !performerLine.isEmpty {
                        Text(performerLine)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(2)
                    }

                    Text(group.totalDurationFormatted)
                        .font(.roonMono(11))
                        .foregroundColor(.roonTertiary)
                }
                .padding(.leading, 16)
                .padding(.vertical, 14)

                Spacer()

                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.18)) { isCollapsed.toggle() }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.roonTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand work" : "Collapse work")
                .padding(.trailing, 6)
                .padding(.top, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.light()
                player.playWork(group)
            }
            .contextMenu {
                Button("Play Work", systemImage: "play.fill") { player.playWork(group) }
                Button("Add to Queue", systemImage: "text.badge.plus") { player.addWorkToQueue(group) }
                Button("Add to Playlist", systemImage: "music.note.list") { showingAddToPlaylist = true }
                Button(isCollapsed ? "Expand" : "Collapse", systemImage: isCollapsed ? "chevron.down" : "chevron.up") {
                    isCollapsed.toggle()
                }
                Divider()
                Button("Fix Work Link…", systemImage: "link.badge.plus") {
                    showingWorkCorrection = true
                }
            }

            Color.roonBorder.frame(height: 0.5).padding(.leading, 16)

            // Movement rows — indented 16pt from left (Roon Arc classical layout)
            if !isCollapsed {
                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    MovementRowView(
                        track:        track,
                        index:        index,
                        isActive:     player.currentTrack?.id == track.id,
                        showPerformer: showPerformer
                    ) {
                        Haptics.light()
                        player.playWork(group, startingAt: index)
                    }
                    .padding(.leading, 16)
                    .id("track-\(track.id)")
                    if index < group.tracks.count - 1 {
                        Color.roonBorder.frame(height: 0.5).padding(.leading, 48)
                    }
                }
            }

            Color.roonDivider.frame(height: 0.5)
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddToPlaylistSheet(tracks: group.tracks)
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .sheet(isPresented: $showingWorkCorrection) {
            WorkCorrectionSheet(group: group)
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
    }
}

// MARK: - Song list

enum SongSortOrder: String, CaseIterable, Identifiable {
    case title     = "Title"
    case artist    = "Artist"
    case album     = "Album"
    case duration  = "Duration"
    var id: String { rawValue }
}

enum FormatFilter: String, CaseIterable, Identifiable {
    case all     = "All"
    case lossless = "Lossless"
    case lossy    = "Lossy"
    var id: String { rawValue }
}

struct SongListView: View {

    @ObservedObject private var library = LibraryViewModel.shared
    @ObservedObject private var player  = PlayerViewModel.shared
    @State private var searchText: String = ""
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty
    @State private var sortOrder: SongSortOrder = .title
    @State private var formatFilter: FormatFilter = .all
    @State private var showSortPicker: Bool = false
    @State private var showFormatPicker: Bool = false

    private var filtered: [Track] {
        var tracks = library.songs
        if !searchNeedle.isEmpty {
            tracks = tracks.filter {
                searchNeedle.matches($0.title) ||
                searchNeedle.matches($0.albumartist ?? "") ||
                searchNeedle.matches($0.trackartist ?? "") ||
                searchNeedle.matches($0.album ?? "")
            }
        }
        switch formatFilter {
        case .lossless: tracks = tracks.filter { $0.lossless == true }
        case .lossy:    tracks = tracks.filter { $0.lossless != true }
        case .all:      break
        }
        switch sortOrder {
        case .title:    tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:   tracks.sort { ($0.trackartist ?? $0.albumartist ?? "").localizedCaseInsensitiveCompare($1.trackartist ?? $1.albumartist ?? "") == .orderedAscending }
        case .album:    tracks.sort { ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending }
        case .duration: tracks.sort { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        return tracks
    }

    private var hasActiveFilter: Bool { formatFilter != .all }

    var body: some View {
        List {
            Section {
                // Filter bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        songFilterChip(label: sortOrder.rawValue, icon: "arrow.up.arrow.down", active: false) { showSortPicker = true }
                        songFilterChip(label: formatFilter == .all ? "Format" : formatFilter.rawValue,
                                       icon: "waveform", active: formatFilter != .all) { showFormatPicker = true }
                        if hasActiveFilter {
                            Button {
                                Haptics.light()
                                formatFilter = .all
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(.roonTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(filtered) { track in
                Button {
                    Haptics.light()
                    player.playSingleTrack(track)
                } label: {
                    SongRowView(track: track, isActive: player.currentTrack?.id == track.id)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.roonBorder)
                // AUDIT-FIX: cursor-based pagination — trigger the next page
                // once the user scrolls within a page-size window of the tail.
                // Only fires while no client-side filter narrows the visible
                // set, otherwise the trigger row may never be reached.
                .onAppear {
                    guard searchNeedle.isEmpty, formatFilter == .all else { return }
                    guard !library.songsExhausted, !library.isLoadingSongs else { return }
                    let triggerOffset = 50
                    if let idx = filtered.firstIndex(where: { $0.id == track.id }),
                       idx >= filtered.count - triggerOffset {
                        Task { await library.loadNextSongsPage() }
                    }
                }
            }
            if library.isLoadingSongs && !library.songs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().tint(.roonAccent)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .searchable(text: $searchText, prompt: "Search songs")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog("Sort Songs", isPresented: $showSortPicker, titleVisibility: .visible) {
            ForEach(SongSortOrder.allCases) { order in
                Button(order.rawValue) { sortOrder = order }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Filter by Format", isPresented: $showFormatPicker, titleVisibility: .visible) {
            ForEach(FormatFilter.allCases) { f in
                Button(f.rawValue) {
                    Haptics.light()
                    formatFilter = f
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay {
            if library.isLoadingSongs && library.songs.isEmpty {
                ProgressView().tint(.roonAccent)
            } else if !library.isLoadingSongs && library.songs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No songs found")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                }
            }
        }
        .task {
            // AUDIT-FIX: load only the first page on entry. Further pages stream
            // in as the user scrolls (see ForEach.onAppear above). Avoids the
            // 30–60s full-library fetch on libraries with 50k+ tracks.
            if library.songs.isEmpty && !library.songsExhausted {
                await library.loadNextSongsPage()
            }
        }
        .onChange(of: searchNeedle) { _, needle in
            // When the user types into the search field we may need more tracks
            // in memory than the first page provides to surface a match. Kick
            // off the next page as a best-effort backfill while server search
            // (in `LibraryViewModel.search`) handles the authoritative answer.
            guard !needle.isEmpty, !library.songsExhausted, !library.isLoadingSongs else { return }
            Task { await library.loadNextSongsPage() }
        }
    }

    @ViewBuilder
    private func songFilterChip(label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.roonBody(13, weight: .semibold))
            }
            .foregroundColor(active ? .white : .roonPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? Color.roonAccent : Color.roonSurface)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(active ? Color.clear : Color.roonBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SongRowView: View {
    let track: Track
    let isActive: Bool
    @ObservedObject private var likedTracks = LikedTracksStore.shared
    @State private var showingAddToPlaylist = false
    @State private var navigateToAlbum: Album? = nil
    @State private var navigateToArtist: Artist? = nil
    @State private var showShareSheet = false

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: track.coverid, size: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(isActive ? .roonAccent : .roonPrimary)
                    .lineLimit(1)

                HStack(spacing: 0) {
                    if let artist = track.trackartist ?? track.albumartist, !artist.isEmpty {
                        Text(artist)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                    }
                    if let albumName = track.album, !albumName.isEmpty {
                        Text(" · ")
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

            DownloadButton(track: track)

            Text(track.durationFormatted)
                .font(.roonMono(12))
                .foregroundColor(.roonTertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button(likedTracks.isLiked(track) ? "Unlike" : "Like", systemImage: likedTracks.isLiked(track) ? "heart.slash" : "heart") {
                likedTracks.toggle(track)
            }
            Button("Play Next", systemImage: "text.insert") {
                PlayerViewModel.shared.playNext([track])
            }
            Button("Add to Queue", systemImage: "text.badge.plus") {
                PlayerViewModel.shared.addTracksToQueue([track])
            }
            Button("Go to Album", systemImage: "square.stack") {
                if let albumID = track.albumID,
                   let album = LibraryViewModel.shared.albums.first(where: { $0.id == albumID }) {
                    navigateToAlbum = album
                }
            }
            Button("Go to Artist", systemImage: "person.crop.circle") {
                let name = track.trackartist ?? track.albumartist ?? ""
                guard !name.isEmpty else { return }
                navigateToArtist = LibraryViewModel.shared.artists.first { $0.name == name }
                    ?? Artist(id: 0, name: name)
            }
            Button("Add to Playlist", systemImage: "music.note.list") {
                showingAddToPlaylist = true
            }
            Button("Share", systemImage: "square.and.arrow.up") {
                showShareSheet = true
            }
            if DownloadManager.shared.isDownloaded(trackID: track.id) {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    if let d = DownloadManager.shared.downloadedTracks.first(where: { $0.id == track.id }) {
                        DownloadManager.shared.removeDownload(d)
                    }
                }
            } else if DownloadManager.shared.downloads[track.id] != nil {
                Button("Cancel Download", systemImage: "xmark.circle") {
                    DownloadManager.shared.cancelDownload(for: track)
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    DownloadManager.shared.download(track)
                }
            }
        }
        .sheet(isPresented: $showingAddToPlaylist) {
            AddToPlaylistSheet(tracks: [track])
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .navigationDestination(item: $navigateToAlbum) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(item: $navigateToArtist) { artist in
            ArtistDetailView(artist: artist)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [HyperionShare.nowPlayingText(track: track)])
                .ignoresSafeArea()
        }
    }
}

// MARK: - Liked tracks

struct LikedTracksView: View {
    @ObservedObject private var likedTracks = LikedTracksStore.shared
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        List {
            if likedTracks.likedTracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "heart")
                        .font(.system(size: 40))
                        .foregroundColor(.roonTertiary)
                    Text("No liked tracks yet")
                        .font(.roonTitle(18))
                        .foregroundColor(.roonPrimary)
                    Text("Tap the heart in Now Playing or use track context menus to build your favorites.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(likedTracks.likedTracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        player.playTracks(likedTracks.likedTracks, startingAt: index)
                    } label: {
                        SongRowView(track: track, isActive: player.currentTrack?.id == track.id)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color.roonBorder)
                }
                .onDelete { offsets in
                    for index in offsets {
                        guard likedTracks.likedTracks.indices.contains(index) else { continue }
                        likedTracks.unlike(likedTracks.likedTracks[index])
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase)
        .navigationTitle("Liked Tracks")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !likedTracks.likedTracks.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Play") { player.playTracks(likedTracks.likedTracks) }
                }
            }
        }
    }
}

// MARK: - Artist list

struct ArtistListView: View {

    @ObservedObject private var library = LibraryViewModel.shared
    @State private var searchText: String = ""
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    private var filtered: [Artist] {
        guard !searchNeedle.isEmpty else { return library.artists }
        return library.artists.filter { searchNeedle.matches($0.name) }
    }

    var body: some View {
        List {
            ForEach(filtered) { artist in
                NavigationLink {
                    ArtistDetailView(artist: artist)
                } label: {
                    ArtistRowView(artist: artist)
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
        .background(Color.roonBase)
        .searchable(text: $searchText, prompt: "Search artists")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay {
            if library.isLoadingArtists && library.artists.isEmpty {
                ProgressView().tint(.roonAccent)
            }
        }
        .task {
            if library.artists.isEmpty { await library.loadArtists() }
        }
    }
}

struct ArtistRowView: View {
    let artist: Artist

    private var initials: String {
        let parts = artist.name.split(separator: " ")
        if parts.count >= 2 {
            return String((parts.first?.prefix(1) ?? "") + (parts.last?.prefix(1) ?? ""))
        }
        return String(artist.name.prefix(2)).uppercased()
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.roonElevated)
                    .frame(width: 46, height: 46)
                Text(initials)
                    .font(.roonTitle(16))
                    .foregroundColor(.roonAccent)
            }
            Text(artist.name)
                .font(.roonBody(16, weight: .medium))
                .foregroundColor(.roonPrimary)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Artist detail (their albums)

struct ArtistDetailView: View {

    let artist: Artist
    @ObservedObject private var library     = LibraryViewModel.shared
    @ObservedObject private var player      = PlayerViewModel.shared
    @ObservedObject private var likedTracks = LikedTracksStore.shared

    @State private var albums:              [Album] = []
    @State private var tracksByArtist:      [Track] = []
    @State private var compositions:        [Work]  = []
    @State private var isLoading:           Bool    = true
    @State private var compositionsLoading: Bool    = false
    @State private var displayedAlbumCount: Int     = 12
    @State private var metadata:            MetadataResult? = nil
    @State private var metadataLoading:     Bool    = false
    @State private var bioExpanded:         Bool    = false
    @State private var selectedTab:         ArtistTab = .overview
    @State private var navigateToSimilarArtist: Artist? = nil

    enum ArtistTab: String, CaseIterable {
        case overview     = "Overview"
        case info         = "Info"
        case discography  = "Discography"
        case compositions = "Compositions"
    }

    private var isClassicalArtist: Bool {
        tracksByArtist.contains { $0.composer != nil } || metadata?.source == .openOpus
    }

    private var visibleTabs: [ArtistTab] {
        isClassicalArtist ? ArtistTab.allCases : ArtistTab.allCases.filter { $0 != .compositions }
    }

    private var lmsComposerID: Int? {
        let folded = SearchTextNormalizer.folded(artist.name)
        return library.composers.first { SearchTextNormalizer.folded($0.artist) == folded }?.id
    }

    private var isArtistLiked: Bool {
        !tracksByArtist.isEmpty && tracksByArtist.allSatisfy { likedTracks.isLiked($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                tabBar
                tabContent
                    .id(selectedTab)
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $navigateToSimilarArtist) { similar in
            ArtistDetailView(artist: similar)
        }
        .task(id: artist.id) {
            isLoading = true
            metadataLoading = true
            displayedAlbumCount = 12
            metadata = nil
            bioExpanded = false
            selectedTab = .overview
            compositions = []
            tracksByArtist = []
            async let detailTask = library.loadArtistDetail(artistID: artist.id)
            async let metaTask   = MetadataService.shared.fetch(artist: artist.name, album: nil, track: nil)
            if let result = try? await detailTask {
                albums = result.albums
                let folded = SearchTextNormalizer.folded(artist.name)
                tracksByArtist = result.songs.filter {
                    SearchTextNormalizer.folded($0.trackartist ?? $0.albumartist ?? "") == folded ||
                    SearchTextNormalizer.folded($0.composer ?? "") == folded
                }
            }
            isLoading = false
            metadata = await metaTask
            metadataLoading = false
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab == .compositions, compositions.isEmpty, !compositionsLoading else { return }
            Task {
                compositionsLoading = true
                if let id = lmsComposerID {
                    compositions = (try? await library.loadWorks(composerID: id)) ?? []
                }
                compositionsLoading = false
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = metadata?.artistImageURL {
                    AsyncArtistHeroImage(url: url)
                } else if let coverid = albums.first?.artwork_track_id {
                    ArtworkView(coverid: coverid, size: 400)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    Color.roonElevated
                }
            }
            .containerRelativeFrame(.vertical) { h, _ in max(h * 0.45, 280) }
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center, endPoint: .bottom
                )
            )

            VStack(alignment: .leading, spacing: 12) {
                Text(artist.name)
                    .font(.roonTitle(32))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Button {
                        player.playTracks(tracksByArtist)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 13))
                            Text("Play Now").font(.roonBody(14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.roonAccent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(tracksByArtist.isEmpty)

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
                            if isArtistLiked {
                                tracksByArtist.filter { likedTracks.isLiked($0) }.forEach { likedTracks.toggle($0) }
                            } else {
                                tracksByArtist.filter { !likedTracks.isLiked($0) }.forEach { likedTracks.toggle($0) }
                            }
                        }
                    } label: {
                        Image(systemName: isArtistLiked ? "heart.fill" : "heart")
                            .font(.system(size: 18))
                            .foregroundColor(isArtistLiked ? .red : .white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(tracksByArtist.isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 0) {
                        Text(tab.rawValue)
                            .font(.roonBody(13, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .roonPrimary : .roonSecondary)
                            .padding(.vertical, 12)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.roonAccent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.roonBase)
        .overlay(Color.roonBorder.frame(height: 0.5), alignment: .bottom)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:     overviewTab
        case .info:         infoTab
        case .discography:  discographyTab
        case .compositions: compositionsTab
        }
    }

    // MARK: - Overview tab

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isLoading {
                ProgressView().tint(.roonAccent).frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                if !tracksByArtist.isEmpty {
                    artistSectionTitle("Popular")
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracksByArtist.prefix(5).enumerated()), id: \.element.id) { index, track in
                            Button {
                                player.playTracks(tracksByArtist, startingAt: index)
                            } label: {
                                SongRowView(track: track, isActive: player.currentTrack?.id == track.id)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            if index < min(4, tracksByArtist.count - 1) {
                                Color.roonBorder.frame(height: 0.5).padding(.leading, 76)
                            }
                        }
                    }
                    .background(Color.roonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)
                }

                if !albums.isEmpty {
                    artistSectionTitle("Albums")
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 16
                    ) {
                        ForEach(Array(albums.prefix(6))) { album in
                            NavigationLink { AlbumDetailView(album: album) } label: {
                                ArtistAlbumGridCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if let similar = metadata?.similarArtists, !similar.isEmpty {
                    artistSectionTitle("Similar Artists")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(similar) { s in
                                Button {
                                    navigateToSimilarArtist = library.artists.first { $0.name == s.name }
                                        ?? Artist(id: 0, name: s.name)
                                } label: {
                                    SimilarArtistCard(similar: s)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                if tracksByArtist.isEmpty && albums.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 44))
                            .foregroundColor(.roonTertiary)
                        Text("No local content found")
                            .font(.roonTitle(18))
                            .foregroundColor(.roonPrimary)
                        Text("No locally indexed albums or tracks for this artist yet.")
                            .font(.roonBody(13))
                            .foregroundColor(.roonSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                    .padding(.horizontal, 32)
                }
            }
            Spacer(minLength: 24)
        }
        .padding(.top, 20)
    }

    // MARK: - Info tab

    private var infoTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            if metadataLoading {
                ProgressView().tint(.roonAccent).frame(maxWidth: .infinity).padding(.top, 40)
            } else if let m = metadata {
                if let bio = m.artistBio, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        artistSectionTitle("About")
                        Text(bio)
                            .font(.body)
                            .foregroundColor(.roonSecondary)
                            .lineLimit(bioExpanded ? nil : 4)
                            .padding(.horizontal, 20)
                        if bioExpanded || bio.count > 200 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() }
                            } label: {
                                Text(bioExpanded ? "Show less" : "Read more")
                                    .font(.roonBody(13, weight: .semibold))
                                    .foregroundColor(.roonAccent)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 20)
                        }
                    }
                }

                if m.artistBorn != nil || m.artistDied != nil {
                    HStack(spacing: 24) {
                        if let born = m.artistBorn {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Born").font(.roonBody(11)).foregroundColor(.roonTertiary)
                                Text(born).font(.roonBody(14, weight: .medium)).foregroundColor(.roonPrimary)
                            }
                        }
                        if let died = m.artistDied {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Died").font(.roonBody(11)).foregroundColor(.roonTertiary)
                                Text(died).font(.roonBody(14, weight: .medium)).foregroundColor(.roonPrimary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                }

                if !m.tags.isEmpty { MetadataTagsRow(tags: m.tags) }

                HStack {
                    Spacer()
                    Text("via \(m.source.displayName)")
                        .font(.roonBody(10, weight: .medium))
                        .foregroundColor(.roonTertiary)
                        .padding(.horizontal, 20)
                }
            } else {
                Text("No info available.")
                    .font(.roonBody(14))
                    .foregroundColor(.roonSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .padding(.horizontal, 20)
            }
            Spacer(minLength: 24)
        }
        .padding(.top, 20)
    }

    // MARK: - Discography tab

    private var discographyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 16
                ) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.roonElevated)
                            .aspectRatio(1, contentMode: .fit)
                            .redacted(reason: .placeholder)
                    }
                }
                .padding(.horizontal, 16)
            } else if !albums.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 16
                ) {
                    ForEach(Array(albums.prefix(displayedAlbumCount))) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: {
                            ArtistAlbumGridCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                    if albums.count > displayedAlbumCount {
                        Color.clear.frame(height: 1).onAppear { displayedAlbumCount += 12 }
                    }
                }
                .padding(.horizontal, 16)
            } else {
                Text("No albums found.")
                    .font(.roonBody(14))
                    .foregroundColor(.roonSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            Spacer(minLength: 24)
        }
        .padding(.top, 16)
    }

    // MARK: - Compositions tab

    private var compositionsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if compositionsLoading {
                ProgressView().tint(.roonAccent).frame(maxWidth: .infinity).padding(.top, 40)
            } else if !compositions.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(compositions) { work in
                        NavigationLink {
                            WorkDetailView(work: work)
                        } label: {
                            WorkRowView(work: work, showComposer: false)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        if work.id != compositions.last?.id {
                            Color.roonBorder.frame(height: 0.5).padding(.leading, 16)
                        }
                    }
                }
                .background(Color.roonSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 16)
            } else {
                Text("No compositions found for this artist.")
                    .font(.roonBody(14))
                    .foregroundColor(.roonSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .padding(.horizontal, 20)
            }
            Spacer(minLength: 24)
        }
        .padding(.top, 16)
    }

    private func artistSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.roonTitle(20))
            .foregroundColor(.roonPrimary)
            .padding(.horizontal, 20)
    }
}

struct MetadataTagsRow: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag.capitalized)
                        .font(.roonBody(12, weight: .medium))
                        .foregroundColor(.roonPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.roonElevated)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.roonBorder, lineWidth: 1))
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct SimilarArtistCard: View {
    let similar: SimilarArtist
    @State private var image: UIImage? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.roonElevated).frame(width: 70, height: 70)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 70, height: 70)
                        .clipShape(Circle())
                } else {
                    Text(NameFormatting.initials(similar.name))
                        .font(.roonTitle(18))
                        .foregroundColor(.roonAccent)
                }
            }
            Text(similar.name)
                .font(.roonBody(11, weight: .medium))
                .foregroundColor(.roonSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 70)
        }
        .task(id: similar.imageURL?.absoluteString) {
            guard let url = similar.imageURL else { return }
            image = await ArtworkCache.shared.loadImage(url: url, targetPoints: 70, scale: 2)
        }
    }
}

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
        List {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AlbumListRow(album: album)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
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

// MARK: - Artist hero image loader

private struct AsyncArtistHeroImage: View {
    let url: URL
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.roonElevated
            }
        }
        .task(id: url.absoluteString) {
            image = await ArtworkCache.shared.loadImage(url: url, targetPoints: 300, scale: 2)
        }
    }
}
