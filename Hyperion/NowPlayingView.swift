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

        var dotColor: Color {
            switch self {
            case .hiRes:       return Color(hex: "#7b6cf6")
            case .lossless:    return Color(red: 0.20, green: 0.85, blue: 0.40)
            case .highQuality: return Color(red: 0.95, green: 0.75, blue: 0.20)
            }
        }
    }

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
        default:              return nil
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @ObservedObject private var player = PlayerViewModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isDraggingProgress: Bool = false
    @State private var dragProgress: Double = 0

    @State private var showSignalPath: Bool = false
    @State private var showQueuePanel: Bool = false
    @State private var showMoreActions: Bool = false

    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingDown: Bool = false

    @State private var isLiked: Bool = false
    @State private var isPillPulsing: Bool = false

    @State private var artworkDragOffset: CGFloat = 0
    @State private var artworkOpacity: Double = 1.0
    @State private var artworkTransitioning: Bool = false
    @State private var artworkSwipeTask: Task<Void, Never>? = nil

    private var qualityPillInfo: (label: String, dotColor: Color, isLosslessOrBetter: Bool) {
        if let lmsQ = player.lmsAudioQuality {
            let tier = lmsQ.tier
            return (tier.label, tier.dotColor, tier != .highQuality)
        }

        let srcFmt = player.sourceFormat.uppercased()
        if !srcFmt.isEmpty && srcFmt != "UNKNOWN" {
            let isLossless = AudioFormats.isLossless(srcFmt)
            let color: Color = isLossless
                ? Color(red: 0.20, green: 0.85, blue: 0.40)
                : Color(red: 0.95, green: 0.75, blue: 0.20)
            return (isLossless ? "Lossless" : "High Quality", color, isLossless)
        }

        if let fmt = player.currentTrack.flatMap({ AudioFormat.from(track: $0) }) {
            let color = fmt.isLossless
                ? Color(red: 0.20, green: 0.85, blue: 0.40)
                : Color(red: 0.95, green: 0.75, blue: 0.20)
            return (fmt.isLossless ? "Lossless" : "High Quality", color, fmt.isLossless)
        }

        return ("Signal", Color.roonTertiary, false)
    }

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

    private var shouldShowQueuePosition: Bool {
        player.queue.count > 1 && player.currentIndex >= 0 && player.currentIndex < player.queue.count
    }

    private var queuePositionText: String {
        let pos = player.currentIndex + 1
        let tot = player.queue.count
        let isSingleWork = player.queueWorkGroups.count == 1
            && player.currentWorkGroup != nil
            && player.currentTrack?.work != nil
            && player.queueWorkGroups.first?.tracks.count == tot
        return isSingleWork ? "Movement \(pos) of \(tot)" : "\(pos) of \(tot)"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer
                .ignoresSafeArea()
                .overlay(backgroundChrome)
                .opacity(isDraggingDown ? max(0.45, 1.0 - dragOffset / 260) : 1.0)

            GeometryReader { geo in
                let safeTop = geo.safeAreaInsets.top
                let safeBottom = geo.safeAreaInsets.bottom
                let contentWidth = max(geo.size.width - 32, 280)
                let usableHeight = max(geo.size.height - safeTop - safeBottom, 480)
                let artworkSide = min(contentWidth, max(260, usableHeight * 0.39))

                VStack(spacing: 0) {
                    headerBar
                        .padding(.horizontal, 16)
                        .padding(.top, safeTop + 6)
                        .padding(.bottom, 4)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            artworkSection(side: artworkSide)
                                .padding(.top, 18)
                                .padding(.bottom, 14)

                            if shouldShowQueuePosition {
                                queuePositionLabel
                                    .padding(.bottom, 10)
                            }

                            trackInfo
                                .padding(.horizontal, 8)
                                .padding(.bottom, 20)

                            progressSection
                                .padding(.bottom, 20)

                            transportControls
                                .padding(.bottom, 30)

                            bottomToolbar
                                .padding(.bottom, max(safeBottom, 20))
                        }
                        .padding(.horizontal, 16)
                        .frame(
                            minWidth: geo.size.width,
                            maxWidth: .infinity,
                            minHeight: usableHeight - 44,
                            alignment: .top
                        )
                    }
                    .simultaneousGesture(swipeDownToDismissGesture)
                }
            }
            .offset(y: dragOffset)
            .animation(isDraggingDown ? .none : .spring(response: 0.34, dampingFraction: 0.84), value: dragOffset)

            if showQueuePanel {
                queuePanelOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) { debugOverlay }
        .gesture(swipeDownToDismissGesture)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showSignalPath) {
            AudioSignalPathView(path: signalPath)
        }
        .confirmationDialog("Now Playing", isPresented: $showMoreActions, titleVisibility: .visible) {
            Button("Queue") {
                Haptics.light()
                withAnimation { showQueuePanel = true }
            }
            Button("Signal Path") {
                Haptics.light()
                showSignalPath = true
            }
            Button(player.isPlaying ? "Pause" : "Play") {
                Haptics.medium()
                player.togglePlayPause()
            }
            Button("Cancel", role: .cancel) { }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.80), value: showQueuePanel)
        .onAppear {
            DispatchQueue.main.async { isPillPulsing = true }
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            isDraggingProgress = false
            dragProgress = 0
            artworkDragOffset = 0
            artworkOpacity = 1.0
            isLiked = false
            artworkSwipeTask?.cancel()
            artworkSwipeTask = nil
            artworkTransitioning = false
        }
        .onDisappear {
            artworkSwipeTask?.cancel()
        }
    }

    @ViewBuilder
    private var debugOverlay: some View {
        #if DEBUG
        AudioDebugToggle()
        #endif
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

    @ViewBuilder
    private var backgroundLayer: some View {
        if let coverid = player.currentTrack?.coverid, !coverid.isEmpty {
            FlatTintBackground(coverid: coverid)
        } else {
            LinearGradient(
                colors: [Color.roonBase, Color.roonSurface.opacity(0.9), Color.roonBase],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var backgroundChrome: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.black.opacity(0.18), location: 0.0),
                    .init(color: Color.black.opacity(0.03), location: 0.22),
                    .init(color: Color.black.opacity(0.22), location: 0.72),
                    .init(color: Color.black.opacity(0.44), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [Color.white.opacity(0.06), Color.clear],
                center: .top,
                startRadius: 30,
                endRadius: 480
            )
            .blendMode(.screen)
        }
    }

    // MARK: - Top bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            TopChromeButton(systemName: "chevron.down", accessibilityLabel: "Close") {
                Haptics.light()
                dismiss()
            }

            Spacer(minLength: 0)

            Button {
                Haptics.light()
                showSignalPath = true
            } label: {
                QualityPillView(
                    label: qualityPillInfo.label,
                    dotColor: qualityPillInfo.dotColor,
                    isAnimating: qualityPillInfo.isLosslessOrBetter,
                    isPillPulsing: isPillPulsing
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio quality: \(qualityPillInfo.label). Tap for signal path.")

            Spacer(minLength: 0)

            TopChromeButton(systemName: "waveform.path", accessibilityLabel: "Signal path details") {
                Haptics.light()
                showSignalPath = true
            }
        }
    }

    // MARK: - Artwork

    private func artworkSection(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.9))

            ArtworkView(
                coverid: player.currentTrack?.coverid,
                size: side,
                contentMode: .fit
            )
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 10)
        .scaleEffect(player.isPlaying ? 1.0 : 0.985)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: player.isPlaying)
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
                artworkDragOffset = value.translation.width * 0.42
                artworkOpacity = max(0.55, 1.0 - abs(value.translation.width) / 420.0)
            }
            .onEnded { value in
                guard !artworkTransitioning else { return }
                let threshold: CGFloat = 60
                if value.translation.width < -threshold {
                    commitArtworkSwipe(direction: .next)
                } else if value.translation.width > threshold {
                    commitArtworkSwipe(direction: .prev)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
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

    private var queuePositionLabel: some View {
        Text(queuePositionText)
            .font(.roonBody(12, weight: .medium))
            .foregroundColor(.roonTertiary)
            .kerning(0.3)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(spacing: 6) {
            Text(player.currentTrack?.title ?? "")
                .font(.system(size: 26, weight: .semibold, design: .default))
                .foregroundColor(.roonPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            let artistLine = player.currentTrack?.composer
                ?? player.currentTrack?.albumartist
                ?? player.currentTrack?.trackartist
                ?? ""
            if !artistLine.isEmpty {
                Text(artistLine)
                    .font(.system(size: 17, weight: .regular, design: .default))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            if let album = player.currentTrack?.album, !album.isEmpty {
                Text(album)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundColor(.roonTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
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
            .frame(height: 22)

            HStack {
                let effectiveDuration = player.duration > 0
                    ? player.duration
                    : (player.currentTrack?.duration ?? 0)
                let displayTime = isDraggingProgress
                    ? dragProgress * effectiveDuration
                    : player.currentTime

                Text(formatTime(displayTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .monospacedDigit()

                Spacer()

                Text(formatTime(effectiveDuration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        HStack(spacing: 0) {
            SmallTransportButton(
                systemName: "shuffle",
                isActive: player.isShuffle,
                accessibilityLabel: player.isShuffle ? "Shuffle on" : "Shuffle off"
            ) {
                Haptics.light()
                player.toggleShuffle()
            }

            Spacer(minLength: 0)

            MainTransportButton(systemName: "backward.fill", size: 28, accessibilityLabel: "Previous track") {
                Haptics.light()
                player.previousTrack()
            }

            Spacer(minLength: 0)

            Button {
                Haptics.medium()
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .frame(width: 92, height: 92)
                    .contentShape(Rectangle())
                    .offset(x: player.isPlaying ? 0 : 2)
            }
            .buttonStyle(.plain)
            .scaleEffect(player.isPlaying ? 1.0 : 0.98)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: player.isPlaying)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer(minLength: 0)

            MainTransportButton(systemName: "forward.fill", size: 28, accessibilityLabel: "Next track") {
                Haptics.light()
                player.nextTrack()
            }

            Spacer(minLength: 0)

            SmallTransportButton(
                systemName: repeatIcon,
                isActive: player.repeatMode > 0,
                accessibilityLabel: repeatAccessibilityLabel
            ) {
                Haptics.light()
                player.cycleRepeat()
            }
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

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            BottomToolbarButton(systemName: "list.bullet.below.rectangle", accessibilityLabel: "Queue") {
                Haptics.light()
                withAnimation { showQueuePanel = true }
            }

            Spacer(minLength: 0)

            BottomToolbarButton(
                systemName: isLiked ? "heart.fill" : "heart",
                tint: isLiked ? .red : .white.opacity(0.36),
                accessibilityLabel: isLiked ? "Unlike" : "Like"
            ) {
                Haptics.light()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
                    isLiked.toggle()
                }
            }

            Spacer(minLength: 0)

            BottomToolbarButton(systemName: "opticaldisc", tint: .white, accessibilityLabel: "Track info & signal path") {
                Haptics.light()
                showSignalPath = true
            }

            Spacer(minLength: 0)

            AirPlayButton()
                .frame(width: 48, height: 48)

            Spacer(minLength: 0)

            BottomToolbarButton(systemName: "ellipsis", accessibilityLabel: "More options") {
                Haptics.light()
                showMoreActions = true
            }
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

// MARK: - Small UI components

private struct TopChromeButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.84))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.16))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct QualityPillView: View {
    let label: String
    let dotColor: Color
    let isAnimating: Bool
    let isPillPulsing: Bool

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)

                if isAnimating {
                    Circle()
                        .stroke(dotColor.opacity(0.42), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .scaleEffect(isPillPulsing ? 2.1 : 1.0)
                        .opacity(isPillPulsing ? 0.0 : 0.75)
                        .animation(
                            .easeOut(duration: 1.35).repeatForever(autoreverses: false),
                            value: isPillPulsing
                        )
                }
            }

            Text(label)
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.22))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

private struct SmallTransportButton: View {
    let systemName: String
    let isActive: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(isActive ? .white.opacity(0.96) : .white.opacity(0.42))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct MainTransportButton: View {
    let systemName: String
    let size: CGFloat
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(.white.opacity(0.96))
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct BottomToolbarButton: View {
    let systemName: String
    var tint: Color = .white.opacity(0.36)
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 21, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - AirPlay button wrapper

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(Color.white.opacity(0.36))
        picker.activeTintColor = UIColor(Color.white)
        picker.prioritizesVideoDevices = false
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
            let clampedDisplay = max(0, min(1, displayProgress))
            let filledWidth = width * clampedDisplay
            let thumbOffset = max(0, min(width - 18, filledWidth - 9))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)

                Capsule()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: max(0, filledWidth), height: 4)

                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.30), radius: 5)
                    .offset(x: thumbOffset)
                    .scaleEffect(isDragging ? 1.18 : 1.0)
                    .animation(.spring(response: 0.2), value: isDragging)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging { Haptics.light() }
                        isDragging = true
                        dragProgress = max(0, min(1, value.location.x / width))
                    }
                    .onEnded { _ in
                        let finalProgress = dragProgress
                        onSeek(finalProgress)
                        isDragging = false
                    }
            )
        }
        .frame(height: 22)
    }
}

// MARK: - Flat tint background

struct FlatTintBackground: View {
    let coverid: String

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil

    private let targetPoints: CGFloat = 420

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 115)
                    .scaleEffect(2.0)
                    .saturation(0.72)
                    .brightness(-0.18)
                    .drawingGroup()
            } else {
                Color.roonBase
            }
        }
        .overlay(Color.black.opacity(0.24))
        .task(id: coverid) {
            let scale = max(displayScale, 1)
            if let cached = ArtworkCache.shared.cachedImage(
                coverid: coverid,
                targetPoints: targetPoints,
                scale: scale
            ) {
                withAnimation(.easeOut(duration: 0.22)) { image = cached }
                return
            }

            let loaded = await ArtworkCache.shared.loadImage(
                coverid: coverid,
                targetPoints: targetPoints,
                scale: scale
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.45)) { image = loaded }
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
