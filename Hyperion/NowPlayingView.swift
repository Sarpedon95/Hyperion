import SwiftUI
import UIKit
import AVKit

// MARK: - LMS Audio Quality Info
//
// Populated by PlayerViewModel from the LMS `status` JSON fields:
//   `samplerate`  – e.g. 44100, 48000, 96000, 192000
//   `samplesize`  – e.g. 16, 24, 32
//   `type`        – e.g. "flac", "alac", "mp3", "aac"
//
// This struct drives the quality pill label and dot color, replacing the
// old file-extension heuristic that missed remote/proxied streams.

struct LMSAudioQuality {
    let sampleRate: Int    // Hz
    let sampleSize: Int    // bits
    let type: String       // codec string from LMS

    /// Maps LMS fields → quality tier following Roon's convention:
    ///   Hi-Res   = lossless codec AND sample rate > 44100 Hz
    ///   Lossless = lossless codec AND sample rate == 44100 Hz
    ///   High Quality = anything else (lossy, or rate unknown)
    var tier: Tier {
        let isLossless = AudioFormats.losslessLowercase.contains(type.lowercased())
        if isLossless && sampleRate > 44100 { return .hiRes }
        if isLossless { return .lossless }
        return .highQuality
    }

    enum Tier {
        case hiRes, lossless, highQuality

        var label: String {
            switch self {
            case .hiRes:       return "Hi-Res"
            case .lossless:    return "Lossless"
            case .highQuality: return "High Quality"
            }
        }

        /// Purple for Hi-Res (Roon uses blue/purple), green for Lossless,
        /// amber for High Quality (matches existing DesignSystem tokens).
        var dotColor: Color {
            switch self {
            case .hiRes:       return Color(hex: "#7b6cf6")                     // purple
            case .lossless:    return Color(red: 0.20, green: 0.85, blue: 0.40) // green
            case .highQuality: return Color(red: 0.95, green: 0.75, blue: 0.20) // amber
            }
        }
    }

    /// Subtitle shown in the signal-path sheet, e.g. "FLAC 96 kHz / 24-bit"
    var detailSubtitle: String {
        let khz = sampleRate >= 1000
            ? String(format: "%.1f kHz", Double(sampleRate) / 1000)
            : "\(sampleRate) Hz"
        let codec = type.uppercased()
        if sampleSize > 0 {
            return "\(codec) \(khz) / \(sampleSize)-bit"
        }
        return "\(codec) \(khz)"
    }
}

// MARK: - Audio format model (legacy fallback from file URL extension)

struct AudioFormat {
    let label: String
    let isLossless: Bool

    var dotColor: Color {
        isLossless
            ? Color(red: 0.2, green: 0.85, blue: 0.4)
            : Color(red: 0.95, green: 0.75, blue: 0.2)
    }

    static func from(track: Track) -> AudioFormat? {
        guard let rawURL = track.url, !rawURL.isEmpty else { return nil }
        let ext: String
        if let u = URL(string: rawURL), !u.pathExtension.isEmpty {
            ext = u.pathExtension.lowercased()
        } else {
            ext = (rawURL as NSString).pathExtension.lowercased()
        }
        switch ext {
        case "flac":         return AudioFormat(label: "FLAC", isLossless: true)
        case "alac":         return AudioFormat(label: "ALAC", isLossless: true)
        case "m4a", "m4b":  return AudioFormat(label: "M4A",  isLossless: false)
        case "wav":          return AudioFormat(label: "WAV",  isLossless: true)
        case "aif", "aiff": return AudioFormat(label: "AIFF", isLossless: true)
        case "mp3":          return AudioFormat(label: "MP3",  isLossless: false)
        case "aac":          return AudioFormat(label: "AAC",  isLossless: false)
        case "ogg":          return AudioFormat(label: "OGG",  isLossless: false)
        default:             return nil
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {

    @ObservedObject private var player = PlayerViewModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isDraggingProgress: Bool = false
    @State private var dragProgress: Double     = 0

    @State private var showSignalPath: Bool = false
    @State private var showQueuePanel: Bool = false

    // Swipe-down-to-dismiss
    @State private var dragOffset: CGFloat  = 0
    @State private var isDraggingDown: Bool = false

    @State private var isLiked: Bool = false

    // Artwork swipe
    @State private var artworkDragOffset: CGFloat = 0
    @State private var artworkOpacity: Double     = 1.0
    @State private var artworkTransitioning: Bool = false
    @State private var artworkSwipeTask: Task<Void, Never>? = nil

    // -------------------------------------------------------------------------
    // Quality pill — resolved in priority order:
    //   1. Live LMS data via lmsAudioQuality on PlayerViewModel (add per patch)
    //   2. File-extension fallback from track URL
    //   3. Generic "Signal" placeholder (so pill is always visible)
    // -------------------------------------------------------------------------
    private var qualityPillInfo: (label: String, dotColor: Color, isLosslessOrBetter: Bool) {
        // Priority 1: Live LMS quality data — uses the canonical colours
        // defined in LMSAudioQuality.Tier so they stay in sync with the struct.
        if let lmsQ = player.lmsAudioQuality {
            let tier = lmsQ.tier
            return (tier.label, tier.dotColor, tier != .highQuality)
        }

        // Priority 2: sourceFormat string set by PlayerViewModel from the track URL extension.
        let srcFmt = player.sourceFormat.uppercased()
        if !srcFmt.isEmpty && srcFmt != "UNKNOWN" {
            let isLossless = AudioFormats.isLossless(srcFmt)
            let color: Color = isLossless
                ? Color(red: 0.20, green: 0.85, blue: 0.40) // green
                : Color(red: 0.95, green: 0.75, blue: 0.20) // amber
            let label = isLossless ? "Lossless" : "High Quality"
            return (label, color, isLossless)
        }
        // Priority 3: URL-extension fallback
        if let fmt = player.currentTrack.flatMap({ AudioFormat.from(track: $0) }) {
            let color = fmt.isLossless
                ? Color(red: 0.20, green: 0.85, blue: 0.40)
                : Color(red: 0.95, green: 0.75, blue: 0.20)
            let label = fmt.isLossless ? "Lossless" : "High Quality"
            return (label, color, fmt.isLossless)
        }
        // Placeholder — pill is always rendered so the tap target exists
        return ("Signal", Color.roonTertiary, false)
    }

    // PERF: `signalPath` is expensive to compute — it allocates multiple
    // AudioPathStep structs (each with a UUID) on every call. Since it's used
    // only by the signal-path sheet, we build it lazily in the sheet's content
    // rather than as a computed var on the view body.
    private var signalPath: AudioSignalPath {
        guard let track = player.currentTrack else { return .mockPath }
        return AudioSignalPath.fromPlaybackState(
            track:        track,
            sourceFormat: player.sourceFormat,
            outputFormat: player.outputFormat,
            isBitPerfect: player.isBitPerfect,
            volume:       player.volume,
            lmsQuality:   player.lmsAudioQuality
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. Blurred artwork ambient background
            backgroundLayer
                .ignoresSafeArea()
                .opacity(isDraggingDown ? max(0.4, 1.0 - dragOffset / 300) : 1.0)

            // 2. Very light scrim at bottom for controls legibility
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.black.opacity(0.00), location: 0.00),
                    .init(color: Color.black.opacity(0.00), location: 0.50),
                    .init(color: Color.black.opacity(0.55), location: 1.00),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 3. Main content column — Roon ARC layout
            GeometryReader { geo in
                let safeTop = geo.safeAreaInsets.top
                let safeBot = geo.safeAreaInsets.bottom
                let screenW = geo.size.width

                VStack(spacing: 0) {
                    // ── Top bar (chevron down | pill | waveform)
                    topBar
                        .padding(.top, safeTop + 6)
                        .padding(.bottom, 4)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {

                            // ── Album art: full width, square, flush to edges
                            artworkSection(side: screenW)
                                .padding(.top, 8)
                                .padding(.bottom, 0)

                            // ── Track metadata — left aligned, Roon ARC style
                            trackInfo
                                .padding(.horizontal, 20)
                                .padding(.top, 18)
                                .padding(.bottom, 4)

                            // ── Progress bar + timestamps
                            progressSection
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                                .padding(.bottom, 4)

                            // ── Transport controls
                            transportControls
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                                .padding(.bottom, 4)

                            // ── Bottom toolbar
                            bottomToolbar
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                                .padding(.bottom, max(safeBot, 20))
                        }
                        .frame(width: screenW)
                    }
                    .simultaneousGesture(swipeDownToDismissGesture)
                }
            }
            .offset(y: dragOffset)
            .animation(isDraggingDown ? .none : .spring(response: 0.38, dampingFraction: 0.82), value: dragOffset)

            // 4. Full queue sheet overlay
            if showQueuePanel {
                queuePanelOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            AudioDebugToggle()
        }
        .gesture(swipeDownToDismissGesture)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showSignalPath) {
            AudioSignalPathView(path: signalPath)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.80), value: showQueuePanel)
        .onChange(of: player.currentTrack?.id) { _, _ in
            isDraggingProgress  = false
            dragProgress        = 0
            artworkDragOffset   = 0
            artworkOpacity      = 1.0
            isLiked             = false
            artworkSwipeTask?.cancel()
            artworkSwipeTask    = nil
            artworkTransitioning = false
        }
        .onDisappear {
            artworkSwipeTask?.cancel()
        }
    }

    // MARK: - Swipe-down-to-dismiss

    private var swipeDownToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                isDraggingDown = true
                dragOffset = value.translation.height * 0.72
            }
            .onEnded { value in
                isDraggingDown = false
                if value.translation.height > 100 || value.predictedEndTranslation.height > 200 {
                    Haptics.light()
                    dismiss()
                } else {
                    dragOffset = 0
                }
            }
    }

    // MARK: - Background
    //
    // Roon ARC style: a flat, deeply-desaturated tint extracted from the album art.
    // We reuse the blurred artwork approach but crank saturation down and brightness
    // way down so the result reads as a near-solid muted hue rather than a bloom.

    @ViewBuilder
    private var backgroundLayer: some View {
        if let coverid = player.currentTrack?.coverid, !coverid.isEmpty {
            FlatTintBackground(coverid: coverid)
        } else {
            Color.roonBase
        }
    }

    // MARK: - Top bar
    //
    // Layout: [chevron.down]  [quality pill]  [waveform icon]
    // The pill is ALWAYS rendered — it shows a placeholder when format is unknown.
    // Using a ZStack with leading/trailing overlay avoids the pill being squeezed
    // by a greedy centre VStack.

    private var topBar: some View {
        let pill = qualityPillInfo
        return ZStack {
            // Centre pill — rendered first so it truly sits at centre
            Button {
                Haptics.light()
                showSignalPath = true
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(pill.dotColor)
                            .frame(width: 9, height: 9)
                        // Pulsing ring for lossless/hi-res
                        if pill.isLosslessOrBetter {
                            Circle()
                                .stroke(pill.dotColor.opacity(0.35), lineWidth: 1.5)
                                .frame(width: 9, height: 9)
                                .scaleEffect(1.5)
                                .opacity(0.6)
                        }
                    }
                    Text(pill.label)
                        .font(.roonBody(13, weight: .semibold))
                        .foregroundColor(.roonPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.roonTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.35))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio quality: \(pill.label). Tap for signal path.")

            // Leading: dismiss chevron
            HStack {
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.roonSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Spacer()
            }

            // Trailing: waveform / signal path icon
            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    showSignalPath = true
                } label: {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.roonTertiary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Signal path details")
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Artwork

    private func artworkSection(side: CGFloat) -> some View {
        // Roon ARC style: full-width square artwork, flush to edges.
        // Use .fit so non-square source images are never zoomed/cropped —
        // letterboxed against the dark background instead.
        ZStack {
            Color.black  // letterbox background for non-square covers

            ArtworkView(
                coverid: player.currentTrack?.coverid,
                size: side,
                contentMode: .fit
            )
        }
        .frame(width: side, height: side)
        .clipped()
        .scaleEffect(player.isPlaying ? 1.0 : 0.98)
        .animation(.easeInOut(duration: 0.22), value: player.isPlaying)
        .offset(x: artworkDragOffset)
        .opacity(artworkOpacity)
        .contentShape(Rectangle())
        .gesture(artworkSwipeGesture)
    }

    private var artworkSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !artworkTransitioning else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                artworkDragOffset = value.translation.width * 0.4
                artworkOpacity = max(0.5, 1.0 - abs(value.translation.width) / 400.0)
            }
            .onEnded { value in
                guard !artworkTransitioning else { return }
                let threshold: CGFloat = 60
                if value.translation.width < -threshold {
                    commitArtworkSwipe(direction: .next)
                } else if value.translation.width > threshold {
                    commitArtworkSwipe(direction: .prev)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        artworkDragOffset = 0
                        artworkOpacity = 1
                    }
                }
            }
    }

    private enum SwipeDirection { case next, prev }

    private func commitArtworkSwipe(direction: SwipeDirection) {
        Haptics.medium()
        artworkTransitioning = true
        artworkSwipeTask?.cancel()
        let exitOffset: CGFloat = direction == .next ? -280 : 280
        let entryOffset: CGFloat = direction == .next ? 280 : -280
        withAnimation(.easeIn(duration: 0.18)) {
            artworkDragOffset = exitOffset
            artworkOpacity = 0
        }
        artworkSwipeTask = Task { @MainActor in
            defer {
                artworkSwipeTask = nil
                artworkTransitioning = false
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            if direction == .next { player.nextTrack() } else { player.previousTrack() }
            artworkDragOffset = entryOffset
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                artworkDragOffset = 0
                artworkOpacity = 1
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Queue position label
    //
    // Subtle caption: small, muted, centred — sits just below the artwork.
    // For a classical work queue shows "Movement X of Y", otherwise "X of Y".

    private var queuePositionLabel: some View {
        let pos = player.currentIndex + 1
        let tot = player.queue.count
        let isSingleWork = player.queueWorkGroups.count == 1
            && player.currentWorkGroup != nil
            && player.currentTrack?.work != nil
            && player.queueWorkGroups.first?.tracks.count == tot
        let label = isSingleWork ? "Movement \(pos) of \(tot)" : "\(pos) of \(tot)"
        return Text(label)
            .font(.roonBody(11, weight: .regular))
            .foregroundColor(.roonTertiary)
            .kerning(0.3)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Track info
    //
    // Roon ARC layout: left-aligned, no small-caps album line above.
    // Large bold title, artist/composer below in secondary colour.

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title — allow up to 2 lines for long classical movement names
            Text(player.currentTrack?.title ?? "")
                .font(.system(size: 22, weight: .bold, design: .default))
                .foregroundColor(.roonPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Artist / composer line
            let artistLine = player.currentTrack?.composer
                          ?? player.currentTrack?.albumartist
                          ?? player.currentTrack?.trackartist
                          ?? ""
            if !artistLine.isEmpty {
                Text(artistLine)
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 8) {
            ProgressBarView(
                progress:     player.progress,
                isDragging:   $isDraggingProgress,
                dragProgress: $dragProgress
            ) { finalProgress in
                player.seek(to: finalProgress * max(player.duration, 1))
            }
            .frame(height: 20)

            HStack {
                let effectiveDuration = player.duration > 0
                    ? player.duration
                    : (player.currentTrack?.duration ?? 0)
                let displayTime = isDraggingProgress
                    ? dragProgress * effectiveDuration
                    : player.currentTime

                // Roon ARC shows elapsed on left, total duration on right
                Text(formatTime(displayTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.roonTertiary)
                    .monospacedDigit()

                Spacer()

                Text(formatTime(effectiveDuration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.roonTertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Transport controls
    //
    // Roon ARC layout: [repeat] [prev] [play/pause] [next] [shuffle]
    // Play button is a large flat icon — no circle background — matching ARC's minimal style.

    private var transportControls: some View {
        HStack(spacing: 0) {
            // Repeat
            Button {
                Haptics.light()
                player.cycleRepeat()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(player.repeatMode > 0 ? .roonAccent : .roonTertiary)
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel(repeatAccessibilityLabel)

            Spacer()

            // Previous
            Button {
                Haptics.light()
                player.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel("Previous track")

            Spacer()

            // Play / Pause — flat large icon, no circle background (Roon ARC style)
            Button {
                Haptics.medium()
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .frame(width: 72, height: 72)
                    .offset(x: player.isPlaying ? 0 : 2)
            }
            .scaleEffect(player.isPlaying ? 1.0 : 0.97)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: player.isPlaying)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            // Next
            Button {
                Haptics.light()
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel("Next track")

            Spacer()

            // Shuffle
            Button {
                Haptics.light()
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(player.isShuffle ? .roonAccent : .roonTertiary)
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel(player.isShuffle ? "Shuffle on" : "Shuffle off")
        }
    }

    private var repeatIcon: String {
        player.repeatMode == 1 ? "repeat.1" : "repeat"
    }

    private var repeatAccessibilityLabel: String {
        switch player.repeatMode {
        case 1:  return "Repeat one"
        case 2:  return "Repeat all"
        default: return "Repeat off"
        }
    }

    // MARK: - Bottom toolbar
    //
    // Roon ARC layout: queue | heart | (centre spacer) | airplay | more (···)
    // Five items, evenly spaced.

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // Queue
            Button {
                Haptics.light()
                withAnimation { showQueuePanel = true }
            } label: {
                Image(systemName: "list.bullet.below.rectangle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.roonTertiary)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Queue")

            Spacer()

            // Heart / Favourite
            Button {
                Haptics.light()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    isLiked.toggle()
                }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isLiked ? .red : .roonTertiary)
                    .scaleEffect(isLiked ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isLiked)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel(isLiked ? "Unlike" : "Like")

            Spacer()

            // Song info / signal path (centre)
            Button {
                Haptics.light()
                showSignalPath = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.roonTertiary)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("Track info & signal path")

            Spacer()

            // AirPlay / output picker
            AirPlayButton()
                .frame(width: 48, height: 48)

            Spacer()

            // Volume (uses speaker icon as a visual anchor for the volume HUD)
            Button {
                Haptics.light()
                // Future: open volume/output picker sheet
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.roonTertiary)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("More options")
        }
    }

    // MARK: - Full queue panel overlay

    private var queuePanelOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showQueuePanel = false }
                    }

                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 36, height: 5)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    HStack {
                        Text("Queue")
                            .font(.roonTitle(20))
                            .foregroundColor(.roonPrimary)
                        Spacer()
                        Button {
                            Haptics.light()
                            withAnimation { showQueuePanel = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.roonTertiary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    Divider().background(Color.roonBorder)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if let current = player.currentTrack {
                                Text("NOW PLAYING")
                                    .font(.roonBody(10, weight: .semibold))
                                    .foregroundColor(.roonAccent)
                                    .kerning(1.4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 14)
                                    .padding(.bottom, 8)

                                InlineNowPlayingRow(track: current)
                                    .padding(.horizontal, 20)
                            }

                            if !player.upcomingWorkGroups.isEmpty {
                                Text("UP NEXT")
                                    .font(.roonBody(10, weight: .semibold))
                                    .foregroundColor(.roonAccent)
                                    .kerning(1.4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 18)
                                    .padding(.bottom, 8)

                                ForEach(player.upcomingWorkGroups) { group in
                                    InlineWorkGroupView(group: group)
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 8)
                                }
                            }

                            Spacer(minLength: 30)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.roonSurface)
                        .ignoresSafeArea(edges: .bottom)
                )
                .frame(maxHeight: geo.size.height * 0.65)
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            if value.translation.height > 60 {
                                withAnimation { showQueuePanel = false }
                            }
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        TimeFormatting.formatDuration(seconds, placeholder: "0:00")
    }
}

// MARK: - AirPlay button wrapper

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor       = UIColor(Color.roonTertiary)
        picker.activeTintColor = UIColor(Color.roonAccent)
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Progress bar

struct ProgressBarView: View {
    let progress: Double
    @Binding var isDragging: Bool
    @Binding var dragProgress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let displayProgress = isDragging ? dragProgress : progress
            let clampedDisplay  = max(0, min(1, displayProgress))
            let filledWidth     = width * clampedDisplay
            let thumbOffset     = max(0, min(width - 16, filledWidth - 8))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.roonAccent)
                    .frame(width: max(0, filledWidth), height: 3)

                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.35), radius: 4)
                    .offset(x: thumbOffset)
                    .scaleEffect(isDragging ? 1.35 : 1.0)
                    .animation(.spring(response: 0.2), value: isDragging)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !isDragging { Haptics.light() }
                        isDragging   = true
                        dragProgress = max(0, min(1, v.location.x / width))
                    }
                    .onEnded { _ in
                        let finalProgress = dragProgress
                        onSeek(finalProgress)
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
    }
}

// MARK: - Flat tint background (Roon ARC style)
//
// Blurs the artwork heavily, crushes saturation and brightness, giving a
// near-solid muted hue rather than a colourful bloom. The result matches
// Roon ARC's "flat deep tint extracted from album art" aesthetic.

struct FlatTintBackground: View {
    let coverid: String

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil

    private let targetPoints: CGFloat = 400

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Heavy blur first — flattens the image to a colour field
                    .blur(radius: 120)
                    .scaleEffect(2.0)
                    // Crush saturation: keeps hue readable but mutes vibrancy
                    .saturation(0.55)
                    // Darken significantly so it reads as a deep tint, not a photo
                    .brightness(-0.28)
                    .drawingGroup()
            } else {
                Color.roonBase
            }
        }
        // Final dark overlay so the minimum brightness never gets too high
        .overlay(Color.black.opacity(0.30))
        .task(id: coverid) {
            let scale = max(displayScale, 1)
            if let cached = ArtworkCache.shared.cachedImage(
                coverid: coverid,
                targetPoints: targetPoints,
                scale: scale
            ) {
                withAnimation(.easeOut(duration: 0.25)) { image = cached }
                return
            }
            let loaded = await ArtworkCache.shared.loadImage(
                coverid: coverid,
                targetPoints: targetPoints,
                scale: scale
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { image = loaded }
        }
    }
}

// MARK: - Blurred artwork background (legacy — kept for reference)

struct AsyncArtworkBackground: View {
    let coverid: String

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil

    private let targetPoints: CGFloat = 400

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                    .saturation(1.1)
                    .drawingGroup()
            } else {
                Color.roonBase
            }
        }
        .task(id: coverid) {
            let scale = max(displayScale, 1)
            if let cached = ArtworkCache.shared.cachedImage(
                coverid: coverid,
                targetPoints: targetPoints,
                scale: scale
            ) {
                withAnimation(.easeOut(duration: 0.25)) { image = cached }
                return
            }
            let loaded = await ArtworkCache.shared.loadImage(
                coverid: coverid,
                targetPoints: targetPoints,
                scale: scale
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { image = loaded }
        }
    }
}

// MARK: - Inline now-playing row (queue panel)

private struct InlineNowPlayingRow: View {
    let track: Track
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: track.coverid, size: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                Text(track.composer ?? track.albumartist ?? "")
                    .font(.roonBody(13))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Group {
                if #available(iOS 17.0, *) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                } else {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.circle")
                }
            }
            .font(.system(size: 16))
            .foregroundColor(.roonAccent)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Inline work group view (queue panel)

private struct InlineWorkGroupView: View {
    let group: QueueWorkGroup
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.workTitle)
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                if let composer = group.composer, !composer.isEmpty {
                    Text(composer)
                        .font(.roonBody(11))
                        .foregroundColor(.roonSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ForEach(group.tracks, id: \.index) { item in
                HStack(spacing: 14) {
                    Text("\(item.index + 1)")
                        .font(.roonMono(11))
                        .foregroundColor(.roonTertiary)
                        .frame(width: 22, alignment: .trailing)

                    Text(item.track.title)
                        .font(.roonBody(13))
                        .foregroundColor(item.index > player.currentIndex ? .roonSecondary : .roonPrimary)
                        .lineLimit(2)

                    Spacer()

                    Text(item.track.durationFormatted)
                        .font(.roonMono(11))
                        .foregroundColor(.roonTertiary)

                    Button {
                        Haptics.light()
                        player.playTrack(at: item.index)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.roonTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())

                if item.index != group.tracks.last?.index {
                    Color.roonBorder.frame(height: 0.5).opacity(0.5).padding(.leading, 52)
                }
            }
        }
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Quality marker pill (legacy — kept for any callers outside NowPlayingView)

struct QualityMarkerView: View {
    let format: AudioFormat?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(format?.label ?? "SIGNAL")
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.roonPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    private var dotColor: Color {
        format?.dotColor ?? Color.roonTertiary
    }
}
