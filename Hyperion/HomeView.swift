import SwiftUI

struct HomeView: View {

    @ObservedObject private var library    = LibraryViewModel.shared
    @ObservedObject private var connection = ConnectionManager.shared

    @State private var showingSettings: Bool = false

    var body: some View {
        NavigationStack {
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

                    // MARK: Recently Played
                    recentlyPlayedSection

                    // MARK: Recently Added
                    if !library.recentAlbums.isEmpty {
                        HomeSectionHeader(label: "YOUR LIBRARY", title: "Recently Added")
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.recentAlbums) { album in
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
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .refreshable {
                await library.refresh()
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
                _ = await (totals, recentAdded, recentPlayed, artistsLoad)
            }
        }
    }

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        HomeSectionHeader(label: "RECENT ACTIVITY", title: "Recently Played")
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

        if library.recentlyPlayed.isEmpty {
            RecentlyPlayedEmptyCard()
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.recentlyPlayed) { album in
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
