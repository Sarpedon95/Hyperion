import Foundation
import WidgetKit

// Writes current track metadata to the shared App Group UserDefaults so
// the HyperionWidget extension can read it without an IPC round-trip.
//
// App Group ID: group.com.sarpedon.hyperion
// Both targets must declare this group in their .entitlements files.

struct NowPlayingWidgetData: Codable {
    var trackTitle: String
    var artist: String
    var album: String
    var isPlaying: Bool
}

final class NowPlayingWidgetStore {
    static let shared = NowPlayingWidgetStore()

    private let suiteName = "group.com.sarpedon.hyperion"
    private let key       = "hyperion.nowplaying.widget"
    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    private init() {}

    func update(track: Track?, isPlaying: Bool) {
        let data = NowPlayingWidgetData(
            trackTitle: track?.title ?? "Not Playing",
            artist:     track?.trackartist ?? track?.albumartist ?? "",
            album:      track?.album ?? "",
            isPlaying:  isPlaying
        )
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults?.set(encoded, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
