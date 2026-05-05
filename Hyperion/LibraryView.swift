import SwiftUI
import UIKit

// MARK: - Library root

struct LibraryView: View {

    var body: some View {
        NavigationStack {
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

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: AlbumListView()) {
                            LibraryMenuRow(icon: "square.stack.fill",        label: "Albums")
                        }
                        .buttonStyle(.plain)

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: ArtistListView()) {
                            LibraryMenuRow(icon: "person.crop.circle.fill",  label: "Artists")
                        }
                        .buttonStyle(.plain)

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: ComposerListView()) {
                            LibraryMenuRow(icon: "person.badge.key.fill",    label: "Composers")
                        }
                        .buttonStyle(.plain)

                        Color.roonBorder.frame(height: 0.5).padding(.leading, 66)

                        NavigationLink(destination: WorkListView(composerID: nil, composerName: nil)) {
                            LibraryMenuRow(icon: "music.quarternote.3",      label: "Works")
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color.roonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 16)

                    Spacer(minLength: 40)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
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
    /// Pre-folded query so SwiftUI layout passes don't re-fold the same string
    /// for every composer in the list. Updated only when searchText changes.
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    private var filtered: [Composer] {
        guard !searchNeedle.isEmpty else { return library.composers }
        return library.composers.filter { searchNeedle.matches($0.artist) }
    }

    var body: some View {
        List {
            ForEach(filtered) { composer in
                NavigationLink {
                    WorkListView(composerID: composer.id, composerName: composer.artist)
                } label: {
                    ComposerRowView(composer: composer)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.roonBase)
        .searchable(text: $searchText, prompt: "Search composers")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle("Composers")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay {
            if library.isLoadingComposers {
                ProgressView().tint(.roonAccent)
            }
        }
        .task {
            if library.composers.isEmpty { await library.loadComposers() }
        }
    }
}

struct ComposerRowView: View {
    let composer: Composer

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
            Text(composer.artist)
                .font(.roonBody(16, weight: .medium))
                .foregroundColor(.roonPrimary)
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
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                }

                if isLoading {
                    ProgressView()
                        .tint(.roonAccent)
                        .padding(40)
                }

                if let error = loadError {
                    Text(error)
                        .font(.roonBody(14))
                        .foregroundColor(.roonSecondary)
                        .padding(20)
                }
            }
        }
        .scrollContentBackground(.hidden)
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
        .task(id: work.id) {
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

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let side = min(geo.size.width * 0.72, 320.0)
                HStack {
                    Spacer(minLength: 0)
                    ArtworkView(coverid: coverid, size: side)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 44)
            .padding(.top, 20)
            .padding(.bottom, 20)

            Text(title)
                .font(.roonTitle(22))
                .foregroundColor(.roonPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.roonBody(15))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.bottom, year != nil ? 2 : 6)
            }

            if let year, year > 0 {
                Text("\(year)")
                    .font(.roonBody(13))
                    .foregroundColor(.roonTertiary)
                    .padding(.bottom, 6)
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

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Group {
                    if isActive {
                        if #available(iOS 17.0, *) {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: true)
                                .font(.system(size: 14))
                                .foregroundColor(.roonAccent)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 14))
                                .foregroundColor(.roonAccent)
                        }
                    } else {
                        Text("\(index + 1)")
                            .font(.roonMono(13))
                            .foregroundColor(.roonTertiary)
                    }
                }
                .frame(width: 24, alignment: .center)
                .padding(.leading, 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.roonBody(15, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .roonAccent : .roonPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if showPerformer, let performer = track.trackartist ?? track.albumartist, !performer.isEmpty {
                        Text(performer)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !track.durationFormatted.isEmpty {
                    Text(track.durationFormatted)
                        .font(.roonMono(12))
                        .foregroundColor(.roonTertiary)
                        .padding(.trailing, 16)
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Album list

struct AlbumListView: View {

    @ObservedObject private var library = LibraryViewModel.shared

    @State private var sortOrder: AlbumSortOrder = .album
    @State private var showSortPicker: Bool = false
    @State private var searchText: String = ""
    /// Tracks the measured scroll-view width so we can derive cellWidth without
    /// using the deprecated UIScreen.main.bounds API (incorrect on Stage Manager
    /// and multi-window iPad). Updated by onGeometryChange on iOS 17+.
    @State private var containerWidth: CGFloat = 390

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    /// 2 columns × 16 spacing + 16+16 horizontal padding = 48 fixed overhead.
    private var cellWidth: CGFloat {
        max(100, (containerWidth - 48) / 2)
    }

    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    // Client-side search filter on already-loaded albums.
    // Server search is handled by SearchView; this is just a quick local filter.
    private var displayedAlbums: [Album] {
        guard !searchNeedle.isEmpty else { return library.albums }
        return library.albums.filter {
            searchNeedle.matches($0.album) ||
            searchNeedle.matches($0.artist ?? "") ||
            searchNeedle.matches($0.composer ?? "")
        }
    }

    var body: some View {
        ScrollView {
            // Filter/sort toolbar
            HStack(spacing: 12) {
                // Sort picker button
                Button {
                    Haptics.light()
                    showSortPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                        Text(sortOrder.rawValue)
                            .font(.roonBody(13, weight: .semibold))
                    }
                    .foregroundColor(.roonPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.roonSurface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.roonBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                if library.isLoadingAlbums && library.albums.isEmpty {
                    ProgressView()
                        .tint(.roonAccent)
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 16)
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
                    Task { await library.loadAlbums(reset: true, sort: order) }
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
}

struct AlbumGridCell: View {
    let album: Album
    /// Pass the computed cell width in from the grid so we avoid a
    /// GeometryReader inside every LazyVGrid cell, which causes an extra
    /// layout pass per-cell and defeats the lazy rendering optimisation.
    var cellWidth: CGFloat = 160

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

// MARK: - Album detail (with Tracks / Info / Credits tabs)

struct AlbumDetailView: View {

    let album: Album

    @ObservedObject private var library = LibraryViewModel.shared
    @ObservedObject private var player  = PlayerViewModel.shared
    @State private var workGroups: [WorkGroup] = []
    @State private var isLoading: Bool         = true
    @State private var loadError: String?      = nil
    @State private var selectedTab: AlbumTab   = .tracks

    enum AlbumTab: String, CaseIterable {
        case tracks  = "TRACKS"
        case info    = "INFO"
        case credits = "CREDITS"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header: artwork + title + artist + year
                CenteredArtworkHeader(
                    coverid:  album.artwork_track_id,
                    title:    album.album,
                    subtitle: album.artist ?? album.composer,
                    year:     album.year
                )

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
                    AlbumInfoPanel(album: album, workGroups: workGroups)
                case .credits:
                    creditsContent
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: album.id) {
            isLoading = true
            loadError = nil
            workGroups = []
            defer { isLoading = false }

            do {
                let groups = try await library.getWorkGroupsForAlbum(album.id)
                guard !Task.isCancelled else { return }
                workGroups = groups
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var tracksContent: some View {
        if isLoading {
            ProgressView().tint(.roonAccent).padding(40)
        } else if let error = loadError {
            Text(error).font(.roonBody(14)).foregroundColor(.roonSecondary).padding(20)
        } else if workGroups.isEmpty {
            Text("No playable tracks were found for this album.")
                .font(.roonBody(14))
                .foregroundColor(.roonSecondary)
                .multilineTextAlignment(.center)
                .padding(32)
                .frame(maxWidth: .infinity)
        } else {
            ForEach(workGroups) { group in
                WorkGroupSectionView(group: group, showPerformer: true)
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
        HStack(spacing: 14) {
            Button {
                Haptics.medium()
                guard !workGroups.isEmpty else { return }
                player.playAlbum(workGroups)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Play Now")
                        .font(.roonBody(16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.roonAccent)
                .clipShape(RoundedRectangle(cornerRadius: 25))
            }
            .buttonStyle(.plain)
            .disabled(workGroups.isEmpty)

            Button {
                Haptics.light()
                player.addWorkGroupsToQueue(workGroups)
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
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.roonBody(13, weight: selected == tab ? .semibold : .regular))
                            .foregroundColor(selected == tab ? .roonPrimary : .roonTertiary)
                            .kerning(0.6)

                        // Underline indicator
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
    }
}

// MARK: - Album info panel

struct AlbumInfoPanel: View {
    let album: Album
    let workGroups: [WorkGroup]

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(coverid: group.coverid, size: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 16)
                    .padding(.vertical, 14)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.workTitle)
                        .font(.roonBody(15, weight: .semibold))
                        .foregroundColor(.roonPrimary)
                        .lineLimit(2)
                    if let composer = group.composer, !composer.isEmpty {
                        Text(composer)
                            .font(.roonBody(13))
                            .foregroundColor(.roonSecondary)
                    }
                    Text(group.totalDurationFormatted)
                        .font(.roonMono(11))
                        .foregroundColor(.roonTertiary)
                        .padding(.top, 2)
                }
                .padding(.vertical, 14)

                Spacer()
            }

            Color.roonBorder.frame(height: 0.5).padding(.leading, 16)

            // Tracks
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
                if index < group.tracks.count - 1 {
                    Color.roonBorder.frame(height: 0.5).padding(.leading, 54)
                }
            }

            Color.roonDivider.frame(height: 0.5)
        }
    }
}

// MARK: - Song list

struct SongListView: View {

    @ObservedObject private var library = LibraryViewModel.shared
    @ObservedObject private var player  = PlayerViewModel.shared
    @State private var searchText: String = ""
    @State private var searchNeedle: SearchTextNormalizer.Needle = .empty

    private var filtered: [Track] {
        guard !searchNeedle.isEmpty else { return library.songs }
        return library.songs.filter {
            searchNeedle.matches($0.title) ||
            searchNeedle.matches($0.albumartist ?? "") ||
            searchNeedle.matches($0.trackartist ?? "") ||
            searchNeedle.matches($0.album ?? "")
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { track in
                Button {
                    Haptics.light()
                    player.playSingleTrack(track)
                } label: {
                    SongRowView(track: track, isActive: player.currentTrack?.id == track.id)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.roonBase)
        .searchable(text: $searchText, prompt: "Search songs")
        .onChange(of: searchText) { _, new in searchNeedle = .init(new) }
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
            if library.songs.isEmpty { await library.loadSongs() }
        }
    }
}

struct SongRowView: View {
    let track: Track
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: track.coverid, size: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.roonBody(15, weight: .medium))
                    .foregroundColor(isActive ? .roonAccent : .roonPrimary)
                    .lineLimit(1)
                if let artist = track.trackartist ?? track.albumartist, !artist.isEmpty {
                    Text(artist)
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.roonMono(12))
                .foregroundColor(.roonTertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.roonBorder)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
        .background(Color.roonBase)
        .navigationTitle(artist.name)
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
        .task(id: artist.id) {
            isLoading = true
            defer { isLoading = false }
            albums = (try? await LyrionAPI.shared.getAlbumsForArtist(artistID: artist.id)) ?? []
            albums.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
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
