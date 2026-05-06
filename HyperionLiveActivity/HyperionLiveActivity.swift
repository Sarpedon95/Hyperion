import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Activity attributes

public struct HyperionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var trackTitle: String
        public var artistName: String
        public var albumTitle: String
        public var isPlaying: Bool
        public var elapsed:   Double
        public var duration:  Double

        public var progress: Double {
            guard duration > 0 else { return 0 }
            return min(max(elapsed / duration, 0), 1)
        }

        public init(
            trackTitle: String,
            artistName: String,
            albumTitle: String,
            isPlaying: Bool,
            elapsed: Double,
            duration: Double
        ) {
            self.trackTitle = trackTitle
            self.artistName = artistName
            self.albumTitle = albumTitle
            self.isPlaying  = isPlaying
            self.elapsed    = elapsed
            self.duration   = duration
        }
    }

    // Static: album art thumbnail sent once at activity start (max 40×40pt JPEG)
    public var albumArtData: Data?

    public init(albumArtData: Data?) {
        self.albumArtData = albumArtData
    }
}

// MARK: - Widget entry point

@main
struct HyperionLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        HyperionLiveActivityWidget()
    }
}

struct HyperionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HyperionActivityAttributes.self) { context in
            // Lock screen / StandBy Live Activity view
            HyperionLockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded view
                DynamicIslandExpandedRegion(.leading) {
                    HyperionArtworkView(data: context.attributes.albumArtData, size: 60)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.trackTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(context.state.artistName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        // Progress bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(.secondary.opacity(0.3))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(.white)
                                    .frame(width: geo.size.width * context.state.progress, height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 12)

                        // Controls
                        HStack(spacing: 32) {
                            Button(intent: HyperionPreviousIntent()) {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .tint(.white)

                            Button(intent: HyperionPlayPauseIntent()) {
                                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                            }
                            .tint(.white)

                            Button(intent: HyperionNextIntent()) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .tint(.white)
                        }
                        .padding(.bottom, 8)
                    }
                }
            } compactLeading: {
                // Compact leading: album art thumbnail
                HyperionArtworkView(data: context.attributes.albumArtData, size: 28)
                    .padding(.leading, 4)
            } compactTrailing: {
                // Compact trailing: playing indicator / track title
                Text(context.state.trackTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.trailing, 4)
            } minimal: {
                // Minimal: album art
                HyperionArtworkView(data: context.attributes.albumArtData, size: 24)
            }
        }
    }
}

// MARK: - Lock screen view

struct HyperionLockScreenView: View {
    let attributes: HyperionActivityAttributes
    let state: HyperionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            HyperionArtworkView(data: attributes.albumArtData, size: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(state.trackTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(state.artistName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(state.albumTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(intent: HyperionPlayPauseIntent()) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.3)).frame(height: 3)
                    Capsule().fill(.primary).frame(width: geo.size.width * state.progress, height: 3)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Artwork helper view

struct HyperionArtworkView: View {
    let data: Data?
    let size: CGFloat

    private var image: UIImage? {
        data.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.secondary.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.12)))
    }
}

// MARK: - App Intents (stubs — implemented in main app target)

import AppIntents

struct HyperionPlayPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    func perform() async throws -> some IntentResult { .result() }
}

struct HyperionNextIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Track"
    func perform() async throws -> some IntentResult { .result() }
}

struct HyperionPreviousIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Track"
    func perform() async throws -> some IntentResult { .result() }
}
