import SwiftUI

struct HomeView: View {

    @Binding var path: NavigationPath

    init(path: Binding<NavigationPath> = .constant(NavigationPath())) {
        _path = path
    }

    @ObservedObject private var library    = LibraryViewModel.shared
    @ObservedObject private var connection = ConnectionManager.shared
    @ObservedObject private var mixGen     = MixGenerator.shared
    @ObservedObject private var audiomuse  = AudiomuseManager.shared

    @AppStorage(ClassicalMode.defaultsKey) private var classicalModeEnabled: Bool = true

    @State private var showingSettings: Bool = false
    @State private var recentActivityTab: RecentActivityTab = .played

    enum RecentActivityTab { case played, added }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    HStack(alignment: .center) {
                        Text("Hyperion")
                            .font(.roonTitle(32))
                            .foregroundColor(.roonPrimary)
                        Spacer()
                        Button { showingSettings = true } label: {
                            Image(systemName: "gear")
                                .font(.system(size: 20))
                                .foregroundColor(.roonSecondary)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .padding(.top, 8)

                    if !connection.isConnected {
                        ConnectionBannerView()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                    }

                    HStack(spacing: 10) {
                        NavigationLink {
                            SongListView()
                        } label: {
                            RoonStatTile(icon: "music.note", value: library.totalSongs, label: "SONGS")
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            AlbumListView()
                        } label: {
                            RoonStatTile(icon: "square.stack", value: library.totalAlbums, label: "ALBUMS")
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ArtistListView()
                        } label: {
                            RoonStatTile(
                                icon: "person.crop.circle",
                                value: library.isLoadingArtists && library.artists.isEmpty
                                    ? nil
                                    : library.totalArtists,
                                label: "ARTISTS"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)

                    // MARK: Recent Activity
                    recentActivitySection

                    // MARK: Daily Mixes
                    mixesSection

                    // MARK: Genres + Liked Tracks (non-classical)
                    // Classical content (composers, works) lives exclusively in
                    // the Classical tab now and never appears on Home.
                    nonClassicalSection

                    // MARK: Artists
                    if !library.artists.isEmpty {
                        HomeSectionHeader(label: "YOUR LIBRARY", title: "Artists")
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(library.artists.prefix(25)) { artist in
                                    NavigationLink {
                                        ArtistDetailView(artist: artist)
                                    } label: {
                                        ArtistCircleCard(artist: artist)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 32)
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
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .refreshable {
                async let libraryRefresh: Void = library.refresh()
                mixGen.refreshIfNeeded()
                await libraryRefresh
            }
            .task {
                // ContentView.task already fires composers / recentAlbums /
                // recentlyPlayed concurrently on app launch.  Here we only
                // kick off the stat-tile counts (cached after first load) and
                // fall back to loading the other data if ContentView hasn't
                // run yet (e.g. deep-link straight to home tab).
                async let totals: Void       = library.loadTotals()
                async let recentAdded: Void  = library.loadRecentAlbums()
                async let recentPlayed: Void = library.loadRecentlyPlayed()
                async let artistsLoad: Void  = library.loadArtists()
                async let genresLoad: Void   = library.loadGenres()
                _ = await (totals, recentAdded, recentPlayed, artistsLoad, genresLoad)
                mixGen.refreshIfNeeded()
            }
        }
    }

    private static let genrePalette: [Color] = [
        .roonAccent, .orange, Color(red: 0.55, green: 0.35, blue: 0.9),
        Color(red: 0.9, green: 0.35, blue: 0.55), .mint, .cyan,
        Color(red: 0.85, green: 0.75, blue: 0.2), Color(red: 0.3, green: 0.75, blue: 0.4)
    ]

    @ViewBuilder
    private var nonClassicalSection: some View {
        // Top Genres row
        if !library.genres.isEmpty {
            HomeSectionHeader(label: "YOUR LIBRARY", title: "Genres")
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(library.genres.prefix(20)) { genre in
                        NavigationLink {
                            GenreAlbumListView(genre: genre)
                        } label: {
                            GenreCard(genre: genre, palette: Self.genrePalette)
                                .frame(width: 110, height: 56)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }

        // Liked Tracks shortcut
        NavigationLink(destination: LikedTracksView()) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.roonElevated)
                        .frame(width: 52, height: 52)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.red.opacity(0.85))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Liked Tracks")
                        .font(.roonBody(16, weight: .semibold))
                        .foregroundColor(.roonPrimary)
                    Text("Your favourites")
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

    @ViewBuilder
    private var mixesSection: some View {
        let showAI        = audiomuse.isEnabled && audiomuse.audiomuseAvailable && !audiomuse.mixes.isEmpty
        let aiGenerating  = audiomuse.isEnabled && audiomuse.audiomuseAvailable && audiomuse.mixes.isEmpty
        // Classical mixes never appear on Home — they belong to the Classical tab.
        let localMixes    = mixGen.mixes.filter { !$0.isClassical }
        let showLocal     = !showAI && !localMixes.isEmpty
        let showSection   = showAI || showLocal || aiGenerating

        if showSection {
            HStack(alignment: .lastTextBaseline) {
                HomeSectionHeader(label: "FOR YOU", title: "Daily Mixes")
                Spacer()
                if showAI {
                    // Play all AI mixes button
                    Button {
                        let ids = audiomuse.mixes.flatMap(\.trackIDs)
                        Task {
                            let player = PlayerViewModel.shared
                            let tracks = await LibraryViewModel.shared.resolveTracks(ids: ids).shuffled()
                            guard !tracks.isEmpty else {
                                Haptics.warning()
                                player.error = "Couldn't load the AI mixes."
                                return
                            }
                            player.playTracks(tracks)
                            Haptics.medium()
                        }
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.roonBody(11, weight: .semibold))
                            .foregroundColor(.roonAccent)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)

                    Text("AI")
                        .font(.roonBody(10, weight: .semibold))
                        .foregroundColor(.roonAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.roonAccent.opacity(0.15))
                        .clipShape(Capsule())
                        .padding(.trailing, 16)
                } else if showLocal {
                    Button {
                        let player = PlayerViewModel.shared
                        let tracks = localMixes.flatMap { mix -> [Track] in
                            let lib = LibraryViewModel.shared
                            let albumSet = Set(mix.albumIDs)
                            return lib.songs.filter { albumSet.contains($0.albumID ?? -1) }
                        }.shuffled()
                        guard !tracks.isEmpty else { return }
                        player.playTracks(tracks)
                        Haptics.medium()
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.roonBody(11, weight: .semibold))
                            .foregroundColor(.roonAccent)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                } else if audiomuse.isEnabled && !audiomuse.audiomuseAvailable {
                    Text("AI unavailable")
                        .font(.roonBody(10))
                        .foregroundColor(.roonTertiary)
                        .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            if aiGenerating {
                // Shimmer placeholder while AI generates mixes
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { _ in
                            MixShimmerCard()
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 32)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        if showAI {
                            ForEach(audiomuse.mixes) { mix in
                                AudiomuseMixCard(mix: mix)
                            }
                        } else {
                            ForEach(localMixes) { mix in
                                MixCard(mix: mix)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private var recentActivitySection: some View {
        // Section header with tab toggle
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("RECENT ACTIVITY")
                    .font(.roonBody(11, weight: .semibold))
                    .foregroundColor(.roonAccent)
                    .kerning(1.4)
                Text("History")
                    .font(.roonTitle(22))
                    .foregroundColor(.roonPrimary)
            }
            Spacer()
            // Played / Added pill toggle
            HStack(spacing: 0) {
                recentTab("Played", tab: .played)
                recentTab("Added", tab: .added)
            }
            .background(Color.roonSurface)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.roonBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)

        let rawItems: [Album] = recentActivityTab == .played
            ? library.recentlyPlayed
            : library.recentAlbums
        // Keep purely-classical albums out of Home when classical mode is off.
        let activeItems: [Album] = classicalModeEnabled
            ? rawItems
            : rawItems.filter { !$0.looksClassical }

        if activeItems.isEmpty {
            if recentActivityTab == .played {
                RecentlyPlayedEmptyCard()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 52, height: 52)
                        Image(systemName: "plus.square.on.square")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.roonAccent)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No recent additions")
                            .font(.roonBody(15, weight: .semibold))
                            .foregroundColor(.roonPrimary)
                        Text("Recently added albums from your library will appear here.")
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Color.roonSurface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(activeItems) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
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
    private func recentTab(_ label: String, tab: RecentActivityTab) -> some View {
        let isActive = recentActivityTab == tab
        Button { withAnimation(.easeInOut(duration: 0.18)) { recentActivityTab = tab } } label: {
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

}

struct RecentlyPlayedEmptyCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 52, height: 52)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.roonAccent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("No recent plays yet")
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                Text("Albums you play in Hyperion will stay here, even when LMS does not record direct AVPlayer playback.")
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct HomeSectionHeader: View {
    let label: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(.roonAccent)
                .kerning(1.4)
            Text(title)
                .font(.roonTitle(22))
                .foregroundColor(.roonPrimary)
        }
    }
}

struct RoonStatTile: View {
    let icon: String
    let value: Int?
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.roonSecondary)
            Text(value.map { Self.format($0) } ?? "—")
                .font(.roonTitle(18))
                .foregroundColor(.roonPrimary)
                .monospacedDigit()
            Text(label)
                .font(.roonBody(10, weight: .semibold))
                .foregroundColor(.roonTertiary)
                .kerning(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static func format(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct RecentAlbumCard: View {
    let album: Album
    private let size: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(coverid: album.artwork_track_id, size: size)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.album)
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                    .frame(width: size, alignment: .leading)
                if let artist = album.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                        .frame(width: size, alignment: .leading)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

struct ComposerCircleCard: View {
    let composer: Composer
    private let size: CGFloat = 80

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.roonElevated)
                    .frame(width: size, height: size)
                Text(NameFormatting.initials(composer.artist))
                    .font(.roonTitle(24))
                    .foregroundColor(.roonAccent)
            }
            Text(NameFormatting.lastName(composer.artist))
                .font(.roonBody(12, weight: .medium))
                .foregroundColor(.roonSecondary)
                .lineLimit(1)
                .frame(width: size + 16)
        }
        .contentShape(Rectangle())
    }
}

struct ArtistCircleCard: View {
    let artist: Artist
    private let size: CGFloat = 80

    private var initials: String {
        let parts = artist.name.split(separator: " ")
        if parts.count >= 2 {
            return String((parts.first?.prefix(1) ?? "") + (parts.last?.prefix(1) ?? ""))
        }
        return String(artist.name.prefix(2)).uppercased()
    }

    private var lastName: String {
        artist.name.split(separator: " ").last.map(String.init) ?? artist.name
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.roonElevated)
                    .frame(width: size, height: size)
                Text(initials)
                    .font(.roonTitle(24))
                    .foregroundColor(.roonAccent)
            }
            Text(lastName)
                .font(.roonBody(12, weight: .medium))
                .foregroundColor(.roonSecondary)
                .lineLimit(1)
                .frame(width: size + 16)
        }
        .contentShape(Rectangle())
    }
}

struct ConnectionBannerView: View {
    @ObservedObject private var connection = ConnectionManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 15))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected")
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                Text(connection.currentURL.isEmpty ? "No server configured" : ServerLogStore.redactedURL(connection.currentURL))
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !connection.lastConnectionMessage.isEmpty {
                    Text(connection.lastConnectionMessage)
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                connection.forceReconnect()
            } label: {
                Text("Retry")
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry connection")
        }
        .padding(14)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
    }
}
