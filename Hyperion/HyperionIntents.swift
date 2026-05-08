import AppIntents
import Foundation

// MARK: - Toggle playback

struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Playback"
    static let description = IntentDescription("Play or pause the current track in Hyperion.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = PlayerViewModel.shared
        if player.currentTrack == nil {
            return .result(dialog: "Nothing is currently loaded in Hyperion.")
        }
        player.togglePlayPause()
        let state = player.isPlaying ? "Playing" : "Paused"
        let title = player.currentTrack?.title ?? ""
        return .result(dialog: "\(state)\(title.isEmpty ? "" : ": \(title)")")
    }
}

// MARK: - Track entity

struct TrackEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Track"
    static let defaultQuery = TrackEntityQuery()

    var id: String
    var title: String
    var artist: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)")
    }
}

struct TrackEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TrackEntity] {
        await LibraryViewModel.shared.loadSongs()
        return await MainActor.run {
            LibraryViewModel.shared.songs
                .filter { identifiers.contains(String($0.id)) }
                .map { TrackEntity(id: String($0.id), title: $0.title, artist: $0.trackartist ?? $0.albumartist ?? "") }
        }
    }

    func entities(matching searchTerm: String) async throws -> [TrackEntity] {
        await LibraryViewModel.shared.loadSongs()
        let needle = searchTerm.lowercased()
        return await MainActor.run {
            Array(
                LibraryViewModel.shared.songs
                    .filter {
                        $0.title.lowercased().contains(needle) ||
                        ($0.trackartist ?? $0.albumartist ?? "").lowercased().contains(needle)
                    }
                    .prefix(10)
                    .map { TrackEntity(id: String($0.id), title: $0.title, artist: $0.trackartist ?? $0.albumartist ?? "") }
            )
        }
    }
}

// MARK: - Play track

struct PlayTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Track"
    static let description = IntentDescription("Play a specific track from your Hyperion library.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Track")
    var track: TrackEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let songs = LibraryViewModel.shared.songs
        guard let match = songs.first(where: { String($0.id) == track.id }) else {
            throw HyperionIntentError.trackNotFound
        }
        PlayerViewModel.shared.playSingleTrack(match)
        return .result(dialog: "Playing \(match.title)")
    }
}

// MARK: - Album entity

struct AlbumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumEntityQuery()

    var id: String
    var title: String
    var artist: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)")
    }
}

struct AlbumEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        await LibraryViewModel.shared.loadAlbums()
        return await MainActor.run {
            LibraryViewModel.shared.albums
                .filter { identifiers.contains(String($0.id)) }
                .map { AlbumEntity(id: String($0.id), title: $0.album, artist: $0.artist ?? $0.composer ?? "") }
        }
    }

    func entities(matching searchTerm: String) async throws -> [AlbumEntity] {
        await LibraryViewModel.shared.loadAlbums()
        let needle = searchTerm.lowercased()
        return await MainActor.run {
            Array(
                LibraryViewModel.shared.albums
                    .filter {
                        $0.album.lowercased().contains(needle) ||
                        ($0.artist ?? "").lowercased().contains(needle) ||
                        ($0.composer ?? "").lowercased().contains(needle)
                    }
                    .prefix(10)
                    .map { AlbumEntity(id: String($0.id), title: $0.album, artist: $0.artist ?? $0.composer ?? "") }
            )
        }
    }
}

// MARK: - Play album

struct PlayAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Play an Album"
    static let description = IntentDescription("Play an album from your Hyperion library.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Album")
    var album: AlbumEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let albumID = Int(album.id) else { throw HyperionIntentError.albumNotFound }
        let workGroups = try await LibraryViewModel.shared.getWorkGroupsForAlbum(albumID)
        guard !workGroups.isEmpty else { throw HyperionIntentError.albumNotFound }
        PlayerViewModel.shared.playAlbum(workGroups)
        return .result(dialog: "Playing \(album.title)")
    }
}

// MARK: - Composer entity

struct ComposerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Composer"
    static let defaultQuery = ComposerEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ComposerEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ComposerEntity] {
        await LibraryViewModel.shared.loadComposers()
        return await MainActor.run {
            LibraryViewModel.shared.composers
                .filter { identifiers.contains(String($0.id)) }
                .map { ComposerEntity(id: String($0.id), name: $0.artist) }
        }
    }

    func entities(matching searchTerm: String) async throws -> [ComposerEntity] {
        await LibraryViewModel.shared.loadComposers()
        let needle = searchTerm.lowercased()
        return await MainActor.run {
            Array(
                LibraryViewModel.shared.composers
                    .filter { $0.artist.lowercased().contains(needle) }
                    .prefix(10)
                    .map { ComposerEntity(id: String($0.id), name: $0.artist) }
            )
        }
    }
}

// MARK: - Play composer

struct PlayComposerIntent: AppIntent {
    static let title: LocalizedStringResource = "Play a Composer"
    static let description = IntentDescription("Play tracks by a composer from your Hyperion library.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Composer")
    var composer: ComposerEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await LibraryViewModel.shared.loadSongs()
        let folded = SearchTextNormalizer.folded(composer.name)
        let tracks = LibraryViewModel.shared.songs.filter {
            SearchTextNormalizer.folded($0.composer ?? "") == folded ||
            SearchTextNormalizer.folded($0.albumartist ?? "") == folded
        }
        guard !tracks.isEmpty else { throw HyperionIntentError.noTracksFound }
        PlayerViewModel.shared.playTracks(tracks)
        return .result(dialog: "Playing \(composer.name)")
    }
}

// MARK: - Artist entity (ADDED: Task 10)

struct ArtistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
    static let defaultQuery = ArtistEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ArtistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        await LibraryViewModel.shared.loadArtists()
        return await MainActor.run {
            LibraryViewModel.shared.artists
                .filter { identifiers.contains(String($0.id)) }
                .map { ArtistEntity(id: String($0.id), name: $0.name) }
        }
    }

    func entities(matching searchTerm: String) async throws -> [ArtistEntity] {
        await LibraryViewModel.shared.loadArtists()
        let needle = searchTerm.lowercased()
        return await MainActor.run {
            Array(
                LibraryViewModel.shared.artists
                    .filter { $0.name.lowercased().contains(needle) }
                    .prefix(10)
                    .map { ArtistEntity(id: String($0.id), name: $0.name) }
            )
        }
    }
}

// MARK: - Play artist (ADDED: Task 10)

struct PlayArtistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play an Artist"
    static let description = IntentDescription("Play tracks by an artist from your Hyperion library.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let artistID = Int(artist.id) else { throw HyperionIntentError.noTracksFound }
        let tracks = try await LyrionAPI.shared.getTracksForArtist(artistID: artistID)
        guard !tracks.isEmpty else { throw HyperionIntentError.noTracksFound }
        PlayerViewModel.shared.playTracks(tracks)
        return .result(dialog: "Playing \(artist.name)")
    }
}

// MARK: - Skip track (ADDED: Task 10)

struct SkipTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Track"
    static let description = IntentDescription("Skip to the next track in Hyperion.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = PlayerViewModel.shared
        guard !player.queue.isEmpty else {
            return .result(dialog: "Nothing is in the queue.")
        }
        player.nextTrack()
        let title = player.currentTrack?.title ?? ""
        return .result(dialog: "Skipping\(title.isEmpty ? "" : " to \(title)")")
    }
}

// MARK: - Errors

enum HyperionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case trackNotFound
    case albumNotFound
    case noTracksFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .trackNotFound:  return "Track not found in your library."
        case .albumNotFound:  return "Album not found or has no playable tracks."
        case .noTracksFound:  return "No tracks found for this composer."
        }
    }
}

// MARK: - Shortcuts provider

struct HyperionShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: [
                "Toggle playback in \(.applicationName)",
                "Play or pause \(.applicationName)"
            ],
            shortTitle: "Toggle Playback",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: PlayTrackIntent(),
            phrases: [
                "Play \(\.$track) in \(.applicationName)",
                "Play the track \(\.$track) with \(.applicationName)"
            ],
            shortTitle: "Play a Track",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play the album \(\.$album) in \(.applicationName)",
                "Play album \(\.$album) with \(.applicationName)"
            ],
            shortTitle: "Play an Album",
            systemImageName: "square.stack"
        )
        AppShortcut(
            intent: PlayComposerIntent(),
            phrases: [
                "Play music by \(\.$composer) in \(.applicationName)",
                "Play \(\.$composer) in \(.applicationName)"
            ],
            shortTitle: "Play by Composer",
            systemImageName: "person.badge.key.fill"
        )
        // ADDED: Task 10
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play \(\.$artist) in \(.applicationName)",
                "Play music by \(\.$artist) with \(.applicationName)"
            ],
            shortTitle: "Play an Artist",
            systemImageName: "music.microphone"
        )
        AppShortcut(
            intent: SkipTrackIntent(),
            phrases: [
                "Skip the track in \(.applicationName)",
                "Next track in \(.applicationName)"
            ],
            shortTitle: "Skip Track",
            systemImageName: "forward.fill"
        )
    }
}
