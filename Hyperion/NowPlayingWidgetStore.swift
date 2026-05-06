import Foundation
import WidgetKit

// Writes current track metadata and an 80 pt artwork thumbnail to the shared
// App Group so the HyperionWidget extension can render without an IPC call.
//
// App Group ID: group.com.sarpedon.hyperion
// Both targets declare this group in their .entitlements files.

struct NowPlayingWidgetData: Codable {
    var trackTitle: String
    var artist: String
    var album: String
    var isPlaying: Bool
}

@MainActor
final class NowPlayingWidgetStore {
    static let shared = NowPlayingWidgetStore()

    private let suiteName = "group.com.sarpedon.hyperion"
    private let key       = "hyperion.nowplaying.widget"
    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    // Artwork file written into the App Group container so the widget can
    // read it as a plain UIImage without any IPC.
    var artworkFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent("widget_artwork.jpg")
    }

    private init() {}

    /// Update the widget's text data and, when a new track starts, write a
    /// fresh artwork thumbnail.  Pass `artworkURL: nil` for play/pause events
    /// where the artwork hasn't changed.
    func update(track: Track?, isPlaying: Bool, artworkURL: URL? = nil) {
        let data = NowPlayingWidgetData(
            trackTitle: track?.title ?? "Not Playing",
            artist:     track?.trackartist ?? track?.albumartist ?? "",
            album:      track?.album ?? "",
            isPlaying:  isPlaying
        )
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults?.set(encoded, forKey: key)

        if let artworkURL {
            // Write the thumbnail off the critical path; reload timelines once done.
            Task {
                await writeArtwork(from: artworkURL)
                WidgetCenter.shared.reloadAllTimelines()
            }
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Private

    private func writeArtwork(from url: URL) async {
        guard let destURL = artworkFileURL else { return }
        // ArtworkCache handles HTTP auth headers, disk cache, and ImageIO downsampling.
        // Scale 3.0 → 240 px for an 80 pt thumbnail; covers all current retina factors.
        let image = await ArtworkCache.shared.loadImage(url: url, targetPoints: 80, scale: 3.0)
        guard let image, let jpeg = image.jpegData(compressionQuality: 0.85) else {
            try? FileManager.default.removeItem(at: destURL)
            return
        }
        try? jpeg.write(to: destURL, options: .atomic)
    }
}
