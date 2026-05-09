import WidgetKit
import SwiftUI

// MARK: - Shared data key (must match NowPlayingWidgetStore in the app target)
//
// IMPORTANT: kGroupSuite must stay in sync with NowPlayingWidgetStore.appGroupSuite
// in the main app target. Both targets must declare the App Group in their .entitlements.

private let kGroupSuite       = "group.com.sarpedon.hyperion"
private let kDataKey          = "hyperion.nowplaying.widget"
private let kArtworkFileName  = "widget_artwork.jpg"   // legacy single-file fallback

// ADDED: Task 7 — data model now includes coverid for per-item artwork lookup.
private struct WidgetNowPlayingData: Codable {
    var trackTitle: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var coverid: String?   // nil in pre-Task-7 data — widget falls back to legacy file
}

// ADDED: Task 7 — resolve artwork URL preferring the per-coverid file, then legacy.
private func artworkImage(forData data: WidgetNowPlayingData) -> UIImage? {
    guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: kGroupSuite
    ) else { return nil }

    // 1. Per-coverid file (written by the main app since Task 7).
    if let cid = data.coverid, !cid.isEmpty {
        let safe = cid.replacingOccurrences(of: "/", with: "_")
                      .replacingOccurrences(of: ":", with: "_")
        let perItem = container.appendingPathComponent("artwork/\(safe).jpg")
        if let img = UIImage(contentsOfFile: perItem.path) { return img }
    }

    // 2. Legacy single-file fallback (widget_artwork.jpg).
    let legacy = container.appendingPathComponent(kArtworkFileName)
    return UIImage(contentsOfFile: legacy.path)
}

// MARK: - Timeline entry

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let artworkImage: UIImage?

    static let placeholder = NowPlayingEntry(
        date: Date(),
        trackTitle: "Track Title",
        artist: "Artist Name",
        album: "Album",
        isPlaying: true,
        artworkImage: nil
    )
    static let empty = NowPlayingEntry(
        date: Date(),
        trackTitle: "Not Playing",
        artist: "Hyperion",
        album: "",
        isPlaying: false,
        artworkImage: nil
    )
}

// MARK: - Timeline provider

struct NowPlayingProvider: TimelineProvider {

    func placeholder(in context: Context) -> NowPlayingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(context.isPreview ? .placeholder : readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // .never — the app calls WidgetCenter.shared.reloadAllTimelines() on track changes.
        completion(Timeline(entries: [readEntry()], policy: .never))
    }

    private func readEntry() -> NowPlayingEntry {
        guard let raw  = UserDefaults(suiteName: kGroupSuite)?.data(forKey: kDataKey),
              let data = try? JSONDecoder().decode(WidgetNowPlayingData.self, from: raw) else {
            return .empty
        }
        // ADDED: Task 7 — prefer per-coverid file; fall back to legacy widget_artwork.jpg.
        let artwork = artworkImage(forData: data)
        return NowPlayingEntry(
            date:         Date(),
            trackTitle:   data.trackTitle,
            artist:       data.artist,
            album:        data.album,
            isPlaying:    data.isPlaying,
            artworkImage: artwork
        )
    }
}

// MARK: - Widget view

struct NowPlayingWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        default:
            rectangularView
        }
    }

    // MARK: Rectangular (lock screen bar)
    private var rectangularView: some View {
        HStack(spacing: 8) {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.2))
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text("HYPERION")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .kerning(0.5)
                } icon: {
                    Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)

                Text(entry.trackTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(entry.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: Circular (watch complication style)
    private var circularView: some View {
        ZStack {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
            } else {
                Circle().fill(.secondary.opacity(0.2))
                Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            if entry.artworkImage != nil {
                Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: Inline (lock screen single line)
    private var inlineView: some View {
        Label {
            Text(entry.isPlaying ? entry.trackTitle : "Paused — \(entry.trackTitle)")
                .lineLimit(1)
        } icon: {
            Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget definition

@main
struct HyperionNowPlayingWidget: Widget {
    let kind: String = "HyperionNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the currently playing track.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
