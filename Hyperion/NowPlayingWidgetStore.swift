import Foundation
import UIKit
import WidgetKit

// Writes current track metadata and an 80 pt artwork thumbnail to the shared
// App Group so the HyperionWidget extension can render without an IPC call.
//
// App Group ID: group.com.sarpedon.hyperion
// Both targets declare this group in their .entitlements files.
//
// ARTWORK STORAGE (Task 7)
// ────────────────────────
// Per-coverid files are written to:
//   <appGroupContainer>/artwork/<sanitisedCoverid>.jpg
//
// This lets the widget survive rapid track changes without a race condition
// (each track keeps its own file) and avoids re-downloading artwork for
// recently-played tracks on the next launch.
//
// The legacy single-file path (widget_artwork.jpg) is kept as a fallback
// for widgets that haven't yet received an updated timeline entry.
//
// A 60-day cleanup pass is run at app launch (see cleanupOldArtwork()).

struct NowPlayingWidgetData: Codable {
    var trackTitle: String
    var artist: String
    var album: String
    var isPlaying: Bool
    // ADDED: Task 7 — coverid lets the widget resolve the per-item artwork file.
    var coverid: String?
}

@MainActor
final class NowPlayingWidgetStore {
    static let shared = NowPlayingWidgetStore()

    // ADDED: Task 7 — App Group suite name is the single source of truth for
    // the main-app target; the widget extension mirrors this in HyperionWidget.swift.
    static let appGroupSuite = "group.com.sarpedon.hyperion"
    private let key          = "hyperion.nowplaying.widget"
    private var defaults: UserDefaults? { UserDefaults(suiteName: Self.appGroupSuite) }

    // Root of the shared App Group container.
    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupSuite)
    }

    // Legacy single-file path kept for widget backward compatibility.
    var artworkFileURL: URL? {
        containerURL?.appendingPathComponent("widget_artwork.jpg")
    }

    // ADDED: Task 7 — Per-coverid artwork directory.
    private var artworkDirURL: URL? {
        containerURL?.appendingPathComponent("artwork", isDirectory: true)
    }

    // ADDED: Task 7 — Stable path for a specific coverid's artwork.
    func artworkURL(forCoverid coverid: String) -> URL? {
        guard !coverid.isEmpty else { return nil }
        // Sanitise: replace characters that are invalid in file names.
        let safe = coverid.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return artworkDirURL?.appendingPathComponent("\(safe).jpg")
    }

    private init() {}

    /// Update the widget's text data and, when a new track starts, write a
    /// fresh artwork thumbnail.  Pass `artworkURL: nil` for play/pause events
    /// where the artwork hasn't changed.
    func update(track: Track?, isPlaying: Bool, artworkURL: URL? = nil) {
        let coverid = track?.coverid ?? ""
        // ADDED: Task 7 — include coverid so the widget can find the per-item file.
        let data = NowPlayingWidgetData(
            trackTitle: track?.title ?? "Not Playing",
            artist:     track?.trackartist ?? track?.albumartist ?? "",
            album:      track?.album ?? "",
            isPlaying:  isPlaying,
            coverid:    coverid.isEmpty ? nil : coverid
        )
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults?.set(encoded, forKey: key)

        if let artworkURL {
            // Write the thumbnail off the critical path; reload timelines once done.
            Task {
                await writeArtwork(coverid: coverid, from: artworkURL)
                WidgetCenter.shared.reloadAllTimelines()
            }
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Cleanup

    /// ADDED: Task 7 — Deletes per-coverid artwork files older than 60 days.
    /// Call once per app launch from a low-priority background Task.
    static func cleanupOldArtwork() {
        // Use the static suite name so this runs entirely off the main actor
        // without crossing the @MainActor isolation boundary.
        let suite = NowPlayingWidgetStore.appGroupSuite
        Task.detached(priority: .background) {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suite
            ) else { return }
            let dir = container.appendingPathComponent("artwork", isDirectory: true)
            let cutoff = Date().addingTimeInterval(-60 * 24 * 60 * 60) // 60 days
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { return }
            for url in contents {
                guard url.pathExtension == "jpg" else { continue }
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate
                if let modified, modified < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Private

    private func writeArtwork(coverid: String, from url: URL) async {
        // ArtworkCache handles HTTP auth headers, disk cache, and ImageIO downsampling.
        // Scale 3.0 → 240 px for an 80 pt thumbnail; covers all current retina factors.
        let image = await ArtworkCache.shared.loadImage(url: url, targetPoints: 80, scale: 3.0)
        guard let image, let jpeg = image.jpegData(compressionQuality: 0.85) else {
            // Remove stale files so the widget falls back gracefully.
            if let dest = artworkURL(forCoverid: coverid) { try? FileManager.default.removeItem(at: dest) }
            if let legacy = artworkFileURL { try? FileManager.default.removeItem(at: legacy) }
            return
        }

        // ADDED: Task 7 — write per-coverid file to artwork/<coverid>.jpg
        if let dir = artworkDirURL {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let dest = artworkURL(forCoverid: coverid) {
            try? jpeg.write(to: dest, options: .atomic)
        }

        // Also maintain the legacy single-file path so existing widget entries
        // that don't yet carry a coverid still display artwork.
        if let legacy = artworkFileURL {
            try? jpeg.write(to: legacy, options: .atomic)
        }
    }
}
