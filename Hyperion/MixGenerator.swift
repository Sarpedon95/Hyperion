import Foundation

// Daily mixes: stable per-week seeds, composer-seeded classical, genre-seeded pop.
// Persisted in Application Support so HomeView shows them instantly on relaunch.

// MARK: - Models

struct LocalMix: Identifiable, Codable {
    let id: UUID
    let title: String
    let subtitle: String
    let seed: String               // composer name or genre name
    let isClassical: Bool
    let albumIDs: [Int]            // up to 4 artwork IDs, first 4 used for grid
    let trackIDs: [Int]            // queue to play
    let generatedAt: Date
}

// MARK: - Generator

@MainActor
final class MixGenerator: ObservableObject {
    static let shared = MixGenerator()

    @Published private(set) var mixes: [LocalMix] = []

    private let filename = "mixes.json"
    private let maxMixes = 6

    private init() {
        load()
    }

    // Call from HomeView.onAppear — regenerates at most once per week.
    func refreshIfNeeded() {
        guard let oldest = mixes.first?.generatedAt else {
            Task { await regenerate() }
            return
        }
        let age = Date().timeIntervalSince(oldest)
        if age > 7 * 24 * 3600 {
            Task { await regenerate() }
        }
    }

    func play(mix: LocalMix, using player: PlayerViewModel) {
        let library = LibraryViewModel.shared
        let albumSet = Set(mix.albumIDs)
        var tracks = library.songs.filter { albumSet.contains($0.albumID ?? -1) }
        if tracks.isEmpty { return }
        tracks.shuffle()
        player.playTracks(tracks)
    }

    // MARK: - Generation

    private func regenerate() async {
        let library = LibraryViewModel.shared
        let weekSeed = weekStableSeed()
        var generated: [LocalMix] = []

        // Classical mixes — seeded by composer
        var composerRNG = SeededRNG(seed: weekSeed)
        let composers = library.composers.shuffled(using: &composerRNG)
        for composer in composers.prefix(3) {
            let albums = library.albums.filter {
                $0.composer?.localizedCaseInsensitiveContains(composer.artist) == true ||
                $0.isClassical == 1
            }
            guard albums.count >= 4 else { continue }
            var albumRNG = SeededRNG(seed: weekSeed &+ UInt64(composer.id))
            let selected = Array(albums.shuffled(using: &albumRNG).prefix(20))
            let mix = LocalMix(
                id: stableID(seed: weekSeed, index: generated.count),
                title: mixTitle(for: composer.artist),
                subtitle: composer.artist,
                seed: composer.artist,
                isClassical: true,
                albumIDs: selected.prefix(4).map(\.id),
                trackIDs: [],
                generatedAt: Date()
            )
            generated.append(mix)
            if generated.count >= maxMixes / 2 { break }
        }

        // Non-classical mixes — seeded by genre
        var genreRNG = SeededRNG(seed: weekSeed &+ 1)
        let genres = library.genres.shuffled(using: &genreRNG)
        for genre in genres.prefix(5) {
            let albums = library.albums.filter {
                $0.isClassical != 1 && $0.composer == nil
            }
            guard albums.count >= 4 else { continue }
            var albumRNG = SeededRNG(seed: weekSeed &+ UInt64(genre.id))
            let selected = Array(albums.shuffled(using: &albumRNG).prefix(20))
            let mix = LocalMix(
                id: stableID(seed: weekSeed, index: generated.count),
                title: "\(genre.name) Mix",
                subtitle: genre.name,
                seed: genre.name,
                isClassical: false,
                albumIDs: selected.prefix(4).map(\.id),
                trackIDs: [],
                generatedAt: Date()
            )
            generated.append(mix)
            if generated.count >= maxMixes { break }
        }

        mixes = generated
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: AppFiles.url(for: filename)),
              let decoded = try? JSONDecoder().decode([LocalMix].self, from: data) else { return }
        mixes = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(mixes) else { return }
        try? data.write(to: AppFiles.url(for: filename), options: .atomicWrite)
    }

    // MARK: - Helpers

    private func weekStableSeed() -> UInt64 {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        let year = UInt64(comps.yearForWeekOfYear ?? 2025)
        let week = UInt64(comps.weekOfYear ?? 1)
        return year &* 53 &+ week
    }

    private func stableID(seed: UInt64, index: Int) -> UUID {
        var rng = SeededRNG(seed: seed &+ UInt64(index) &+ 0xDEAD_BEEF)
        let a = rng.next()
        let b = rng.next()
        return UUID(uuid: (
            UInt8(a & 0xFF), UInt8((a >> 8) & 0xFF), UInt8((a >> 16) & 0xFF), UInt8((a >> 24) & 0xFF),
            UInt8((a >> 32) & 0xFF), UInt8((a >> 40) & 0xFF),
            UInt8(0x40 | ((a >> 48) & 0x0F)), UInt8((a >> 56) & 0xFF),
            UInt8(0x80 | (b & 0x3F)), UInt8((b >> 8) & 0xFF),
            UInt8((b >> 16) & 0xFF), UInt8((b >> 24) & 0xFF),
            UInt8((b >> 32) & 0xFF), UInt8((b >> 40) & 0xFF),
            UInt8((b >> 48) & 0xFF), UInt8((b >> 56) & 0xFF)
        ))
    }

    private func mixTitle(for composer: String) -> String {
        let parts = composer.components(separatedBy: " ")
        let lastName = parts.last ?? composer
        return "\(lastName) Essentials"
    }
}

// MARK: - Seeded RNG (xoshiro256**)

private struct SeededRNG: RandomNumberGenerator {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        var s = seed == 0 ? 1 : seed
        func splitmix(_ x: inout UInt64) -> UInt64 {
            x &+= 0x9E3779B97F4A7C15
            var z = x
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        state = (splitmix(&s), splitmix(&s), splitmix(&s), splitmix(&s))
    }

    mutating func next() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17
        state.2 ^= state.0; state.3 ^= state.1
        state.1 ^= state.2; state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }
}
