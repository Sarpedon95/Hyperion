import WidgetKit
import SwiftUI

// MARK: - Shared data key (must match NowPlayingWidgetStore in the app target)

private let kGroupSuite = "group.com.sarpedon.hyperion"
private let kDataKey    = "hyperion.nowplaying.widget"

private struct WidgetNowPlayingData: Codable {
    var trackTitle: String
    var artist: String
    var album: String
    var isPlaying: Bool
}

// MARK: - Timeline entry

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let trackTitle: String
    let artist: String
    let album: String
    let isPlaying: Bool

    static let placeholder = NowPlayingEntry(
        date: Date(),
        trackTitle: "Track Title",
        artist: "Artist Name",
        album: "Album",
        isPlaying: true
    )
    static let empty = NowPlayingEntry(
        date: Date(),
        trackTitle: "Not Playing",
        artist: "Hyperion",
        album: "",
        isPlaying: false
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
        return NowPlayingEntry(
            date:       Date(),
            trackTitle: data.trackTitle,
            artist:     data.artist,
            album:      data.album,
            isPlaying:  data.isPlaying
        )
    }
}

// MARK: - Widget view

struct NowPlayingWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Header row
            Label {
                Text("HYPERION")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(0.5)
            } icon: {
                Image(systemName: entry.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            // Track title
            Text(entry.trackTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // Artist
            Text(entry.artist)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        .supportedFamilies([.accessoryRectangular])
    }
}
