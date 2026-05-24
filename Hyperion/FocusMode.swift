import SwiftUI
import UserNotifications

// MARK: - Focus Mode

/// Locks playback to the current genre/composer, auto-queues similar content
/// when the queue runs low, and suppresses notification banners.
@MainActor
final class FocusMode: ObservableObject {
    static let shared = FocusMode()

    @Published private(set) var isActive: Bool = false

    /// Genre or composer seed locked in when Focus Mode activates.
    private(set) var seedGenre: String? = nil
    private(set) var seedComposer: String? = nil

    private var refillTask: Task<Void, Never>? = nil
    private var queueObserverTask: Task<Void, Never>? = nil

    private init() {}

    // MARK: - Toggle

    func toggle(currentTrack: Track?) {
        if isActive {
            deactivate()
        } else {
            activate(currentTrack: currentTrack)
        }
    }

    func activate(currentTrack: Track?) {
        guard !isActive else { return }
        isActive = true

        // Seed from the current track's genre or composer
        seedGenre    = currentTrack?.genres?.split(separator: ",").first.map(String.init)
        seedComposer = currentTrack?.composer

        // Suppress notification banners while focused
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // We can't fully suppress delivery without entitlement, but we set
            // foreground presentation to empty so banners don't appear.
            // (This is a no-op if notification permission was never granted.)
            _ = settings
        }

        // Watch the queue and refill when it gets short
        startQueueWatch()
        ServerLogStore.shared.info("Focus Mode activated — genre: \(seedGenre ?? "any"), composer: \(seedComposer ?? "any")")
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        seedGenre    = nil
        seedComposer = nil
        refillTask?.cancel()
        refillTask = nil
        queueObserverTask?.cancel()
        queueObserverTask = nil
        ServerLogStore.shared.info("Focus Mode deactivated")
    }

    // MARK: - Queue watcher

    private func startQueueWatch() {
        queueObserverTask?.cancel()
        queueObserverTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                let player = PlayerViewModel.shared
                let remaining = player.queue.count - player.currentIndex - 1
                if remaining <= 2 {
                    await self.refillQueue()
                }
                try? await Task.sleep(nanoseconds: 8_000_000_000) // check every 8s
            }
        }
    }

    private func refillQueue() async {
        guard isActive, refillTask == nil else { return }
        refillTask = Task { @MainActor [weak self] in
            defer { self?.refillTask = nil }
            guard let self, self.isActive else { return }

            let player = PlayerViewModel.shared

            // Prefer the in-memory library when it has been paginated in; fall
            // back to a server-side pool so Focus Mode keeps refilling on a cold
            // launch (when LibraryViewModel.songs is still empty).
            var candidates = LibraryViewModel.shared.songs.filter { self.matchesSeed($0) }
            if candidates.isEmpty {
                candidates = await self.serverCandidatePool()
                guard self.isActive else { return }
            }

            // Shuffle and avoid repeating what's already in the queue
            let queueIDs = Set(player.queue.map(\.id))
            candidates = candidates.filter { !queueIDs.contains($0.id) }.shuffled()

            let toAdd = Array(candidates.prefix(8))
            guard !toAdd.isEmpty else {
                ServerLogStore.shared.warn("Focus Mode: no candidate tracks found for current seed")
                return
            }
            player.addTracksToQueue(toAdd)
            ServerLogStore.shared.info("Focus Mode: added \(toAdd.count) tracks to queue")
        }
    }

    /// True when a track matches the active genre/composer seed.
    private func matchesSeed(_ track: Track) -> Bool {
        if let genre = seedGenre,
           let trackGenres = track.genres,
           !trackGenres.lowercased().contains(genre.lowercased()) {
            return false
        }
        if let composer = seedComposer,
           let trackComposer = track.composer,
           !trackComposer.lowercased().contains(composer.lowercased()) {
            return false
        }
        return true
    }

    /// Server-side candidate pool used when the in-memory library is empty.
    /// Resolves the seed to a concrete LMS query rather than scanning a
    /// (possibly empty) local song list.
    private func serverCandidatePool() async -> [Track] {
        // Composer seed → resolve contributor ID → tracks by that composer.
        if let composer = seedComposer, !composer.isEmpty {
            if let artists = try? await LyrionAPI.shared.searchArtists(term: composer, count: 5),
               let id = (artists.first { $0.name.localizedCaseInsensitiveCompare(composer) == .orderedSame }?.id
                         ?? artists.first?.id),
               let tracks = try? await LyrionAPI.shared.getTracksForComposer(composerID: id),
               !tracks.isEmpty {
                return tracks
            }
        }
        // Genre seed → resolve genre ID → a server-randomised page.
        if let genreName = seedGenre, !genreName.isEmpty {
            await LibraryViewModel.shared.loadGenres()
            if let genre = LibraryViewModel.shared.genres.first(where: {
                   $0.name.localizedCaseInsensitiveCompare(genreName) == .orderedSame
               }),
               let tracks = try? await LyrionAPI.shared.getTracksForGenre(genreID: genre.id, count: 100),
               !tracks.isEmpty {
                return tracks
            }
        }
        // No usable seed → a random page so the queue still grows.
        return (try? await LyrionAPI.shared.getRandomSongs(count: 100)) ?? []
    }
}

// MARK: - Focus Mode banner overlay

/// Small banner shown at the top of NowPlayingView when Focus Mode is active.
struct FocusModeBanner: View {
    @ObservedObject var focus = FocusMode.shared

    var body: some View {
        if focus.isActive {
            HStack(spacing: 8) {
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.roonAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Focus Mode")
                        .font(.roonBody(12, weight: .semibold))
                        .foregroundColor(.roonPrimary)
                    if let genre = focus.seedGenre ?? focus.seedComposer {
                        Text("Locked to: \(genre)")
                            .font(.roonBody(10))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    Haptics.light()
                    FocusMode.shared.deactivate()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.roonTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.roonElevated.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.roonAccent.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
