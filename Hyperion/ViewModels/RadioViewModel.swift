import Foundation
import Combine

@MainActor
final class RadioViewModel: ObservableObject {

    @Published var featuredStations: [RadioStation] = []
    @Published var searchResults: [RadioStation] = []
    @Published var browseResults: [RadioStation] = []
    @Published var currentStation: RadioStation? = nil
    @Published var isLoading = false
    @Published var searchText = ""
    @Published var selectedGenreFilter: RadioGenre? = nil

    enum RadioGenre: String, CaseIterable, Identifiable {
        case electronic = "electronic"
        case trance     = "trance"
        case house      = "house"
        case classical  = "classical"
        case jazz       = "jazz"
        case rock       = "rock"
        case pop        = "pop"
        case ambient    = "ambient"
        case chillout   = "chillout"
        case news       = "news"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .electronic: return "Electronic"
            case .trance:     return "Trance"
            case .house:      return "House"
            case .classical:  return "Classical"
            case .jazz:       return "Jazz"
            case .rock:       return "Rock"
            case .pop:        return "Pop"
            case .ambient:    return "Ambient"
            case .chillout:   return "Chillout"
            case .news:       return "News"
            }
        }

        var icon: String {
            switch self {
            case .electronic: return "waveform.path"
            case .trance:     return "bolt.fill"
            case .house:      return "house.fill"
            case .classical:  return "music.quarternote.3"
            case .jazz:       return "saxophone"
            case .rock:       return "guitars.fill"
            case .pop:        return "star.fill"
            case .ambient:    return "moon.stars.fill"
            case .chillout:   return "leaf.fill"
            case .news:       return "newspaper.fill"
            }
        }
    }

    private var didLoadFeatured = false
    private var searchTask: Task<Void, Never>? = nil

    // Mirror the player's current radio station so the UI shows the playing
    // indicator regardless of where playback was started.
    private var cancellable: AnyCancellable?

    init() {
        cancellable = PlayerViewModel.shared.$currentRadioStation
            .receive(on: RunLoop.main)
            .sink { [weak self] station in
                self?.currentStation = station
            }
    }

    // MARK: - Featured

    func loadFeaturedStations() async {
        guard !didLoadFeatured else { return }
        didLoadFeatured = true
        // Show the hardcoded list immediately so the section is never empty.
        featuredStations = FeaturedRadioStations.stations()

        // Refresh each station's stream URL + metadata from RadioBrowser in the
        // background. Failures keep the fallback entry untouched.
        let seeds = FeaturedRadioStations.seeds
        var refreshed = featuredStations
        await withTaskGroup(of: (Int, RadioStation?).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    let match = await RadioBrowserAPI.shared.bestMatch(name: seed.name)
                    return (index, match)
                }
            }
            for await (index, match) in group {
                guard let match, refreshed.indices.contains(index) else { continue }
                let fallback = refreshed[index]
                // Keep the curated identity (featured flag, brand genre) but take
                // the verified stream URL / logo / bitrate from RadioBrowser.
                refreshed[index] = RadioStation(
                    id:        fallback.id,
                    name:      fallback.name,
                    streamURL: match.streamURL,
                    genre:     fallback.genre ?? match.genre,
                    country:   fallback.country ?? match.country,
                    language:  fallback.language ?? match.language,
                    logoURL:   match.logoURL ?? fallback.logoURL,
                    bitrate:   match.bitrate,
                    codec:     match.codec,
                    votes:     match.votes,
                    isFeatured: true
                )
            }
        }
        featuredStations = refreshed
    }

    // MARK: - Search (debounced)

    func search(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isLoading = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)   // 400 ms debounce
            guard !Task.isCancelled, let self else { return }
            self.isLoading = true
            self.browseResults = []
            self.selectedGenreFilter = nil
            let results = await RadioBrowserAPI.shared.searchStations(query: trimmed)
            guard !Task.isCancelled else { return }
            self.searchResults = results
            self.isLoading = false
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        isLoading = false
    }

    // MARK: - Browse by genre

    func browseGenre(_ genre: RadioGenre) async {
        searchTask?.cancel()
        selectedGenreFilter = genre
        searchResults = []
        searchText = ""
        isLoading = true
        let results = await RadioBrowserAPI.shared.browseByGenre(tag: genre.rawValue)
        guard selectedGenreFilter == genre else { return }
        browseResults = results
        isLoading = false
    }

    // MARK: - Playback

    func play(station: RadioStation) async {
        currentStation = station
        PlayerViewModel.shared.playRadioStation(station)
        await RadioBrowserAPI.shared.recordClick(stationUUID: station.id)
    }

    func stop() {
        currentStation = nil
        PlayerViewModel.shared.stopRadioStation()
    }

    /// True when the given station is the one currently streaming.
    func isPlaying(_ station: RadioStation) -> Bool {
        currentStation?.id == station.id
    }
}
