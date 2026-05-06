import Foundation
import Combine

// MARK: - Model

struct AudiomuseMix: Identifiable, Codable {
    let id: UUID
    let title: String
    let seedDescription: String
    let trackIDs: [Int]
    let albumIDs: [Int]
    let generatedAt: Date
}

// MARK: - Manager

@MainActor
final class AudiomuseManager: ObservableObject {

    static let shared = AudiomuseManager()

    @Published private(set) var mixes: [AudiomuseMix] = []
    @Published private(set) var audiomuseAvailable: Bool = false
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastRefreshError: String? = nil

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "hyperion.audiomuse.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "hyperion.audiomuse.enabled") }
    }

    private let filename = "audiomuse_mixes.json"
    private let refreshInterval: TimeInterval = 3600
    private let requestTimeout: TimeInterval = 5

    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?

    private init() {
        loadCached()
        observeConnection()
    }

    // MARK: - Settings actions

    /// Manual "Test AudioMuse Connection" — probes the endpoint and reports back.
    func testConnection() async -> String {
        guard let url = audiomuseBaseURL() else {
            return "No server configured"
        }
        let probeURL = url.appendingPathComponent("api/mix")
        guard var components = URLComponents(url: probeURL, resolvingAgainstBaseURL: false) else { return "Invalid URL" }
        components.queryItems = [URLQueryItem(name: "count", value: "1")]
        guard let finalURL = components.url else { return "Invalid URL" }

        do {
            let result = try await fetch(url: finalURL)
            if result != nil {
                return "AudioMuse plugin is available at \(url.absoluteString)"
            } else {
                return "AudioMuse plugin not found (check LMS plugin list)"
            }
        } catch {
            return "Connection failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Connection observer

    private func observeConnection() {
        ConnectionManager.shared.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, connected, self.isEnabled else { return }
                    await self.probeAndRefreshIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Probe + refresh

    func probeAndRefreshIfNeeded() async {
        guard isEnabled else { return }
        guard let url = audiomuseBaseURL() else { return }

        let available = await probeAvailability(baseURL: url)
        audiomuseAvailable = available
        if !available { return }

        // Refresh at most once per hour; serve stale cache while refreshing.
        if let newest = mixes.first?.generatedAt,
           Date().timeIntervalSince(newest) < refreshInterval {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard isEnabled, let url = audiomuseBaseURL() else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }

        do {
            let newMixes = try await generateMixes(baseURL: url)
            if !newMixes.isEmpty {
                mixes = newMixes
                saveCached()
            }
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: - Availability probe

    private func probeAvailability(baseURL: URL) async -> Bool {
        let probeURL = baseURL.appendingPathComponent("api/mix")
        guard var comps = URLComponents(url: probeURL, resolvingAgainstBaseURL: false) else { return false }
        comps.queryItems = [URLQueryItem(name: "count", value: "1")]
        guard let url = comps.url else { return false }
        return (try? await fetch(url: url)) != nil
    }

    // MARK: - Mix generation (6 mixes, parallel)

    private func generateMixes(baseURL: URL) async throws -> [AudiomuseMix] {
        let library = LibraryViewModel.shared
        let artists = Array(library.artists.prefix(3))
        let genres  = Array(library.genres.prefix(2))
        let liked   = LikedTracksStore.shared.likedTracks.randomElement()

        let seed0 = artists[safe: 0].map { "artist:\($0.name)" } ?? "random"
        let seed1 = artists[safe: 1].map { "artist:\($0.name)" } ?? "random"
        let seed2 = artists[safe: 2].map { "artist:\($0.name)" } ?? "random"
        let seed3 = genres[safe: 0].map  { "genre:\($0.name)"  } ?? "random"
        let seed4 = genres[safe: 1].map  { "genre:\($0.name)"  } ?? "random"
        let seed5 = liked.map            { "track:\($0.id)"     } ?? "random"

        async let m0 = fetchMix(baseURL: baseURL, seed: seed0)
        async let m1 = fetchMix(baseURL: baseURL, seed: seed1)
        async let m2 = fetchMix(baseURL: baseURL, seed: seed2)
        async let m3 = fetchMix(baseURL: baseURL, seed: seed3)
        async let m4 = fetchMix(baseURL: baseURL, seed: seed4)
        async let m5 = fetchMix(baseURL: baseURL, seed: seed5)

        let (r0, r1, r2, r3, r4, r5) = await (m0, m1, m2, m3, m4, m5)
        return [r0, r1, r2, r3, r4, r5].compactMap { $0 }
    }

    private func fetchMix(baseURL: URL, seed: String) async -> AudiomuseMix? {
        let mixURL = baseURL.appendingPathComponent("api/mix")
        guard var comps = URLComponents(url: mixURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "seed",  value: seed),
            URLQueryItem(name: "count", value: "20")
        ]
        guard let url = comps.url else { return nil }
        guard let payload = try? await fetch(url: url) else { return nil }

        // Expected response: { "tracks": [...], "title": "...", "seed": "..." }
        let title = (payload["title"] as? String) ?? humanTitle(for: seed)
        let ids: [Int]
        if let arr = payload["tracks"] as? [[String: Any]] {
            ids = arr.compactMap { Self.intValue($0["id"] ?? $0["track_id"]) }
        } else if let arr = payload["tracks"] as? [Int] {
            ids = arr
        } else {
            return nil
        }
        guard !ids.isEmpty else { return nil }

        // Derive album IDs for artwork grid from the library.
        let songs = LibraryViewModel.shared.songs
        let albumIDs: [Int] = Array(
            Set(ids.compactMap { id in songs.first(where: { $0.id == id })?.albumID })
                .prefix(4)
        )

        return AudiomuseMix(
            id: UUID(),
            title: title,
            seedDescription: seed,
            trackIDs: ids,
            albumIDs: albumIDs,
            generatedAt: Date()
        )
    }

    // MARK: - Play a mix

    func play(mix: AudiomuseMix, using player: PlayerViewModel) {
        let songs = LibraryViewModel.shared.songs
        var tracks = mix.trackIDs.compactMap { id in songs.first(where: { $0.id == id }) }
        if tracks.isEmpty { return }
        tracks.shuffle()
        player.playTracks(tracks)
    }

    // MARK: - Networking

    private func fetch(url: URL) async throws -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        // Add LMS auth headers if configured.
        let headers = LyrionAPI.shared.httpHeaders(accept: "application/json")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Persistence

    private func loadCached() {
        guard let data = try? Data(contentsOf: AppFiles.url(for: filename)),
              let decoded = try? JSONDecoder().decode([AudiomuseMix].self, from: data) else { return }
        mixes = decoded
    }

    private func saveCached() {
        guard let data = try? JSONEncoder().encode(mixes) else { return }
        try? data.write(to: AppFiles.url(for: filename), options: .atomicWrite)
    }

    // MARK: - Helpers

    private func audiomuseBaseURL() -> URL? {
        let base = LyrionAPI.shared.baseURL
        guard !base.isEmpty, let url = URL(string: base) else { return nil }
        return url.appendingPathComponent("audiomuse")
    }

    private func humanTitle(for seed: String) -> String {
        if seed.hasPrefix("artist:") { return "\(seed.dropFirst(7)) Mix" }
        if seed.hasPrefix("genre:")  { return "\(seed.dropFirst(6)) Mix" }
        if seed.hasPrefix("track:")  { return "Liked Tracks Mix" }
        return "Daily Mix"
    }

    private nonisolated static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int:    return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default:              return nil
        }
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
