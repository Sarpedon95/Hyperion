import SwiftUI
import UIKit
import AVKit

// MARK: - LMS / Lyrion Audio Metadata
//
// Populated by PlayerViewModel from LMS `songinfo` and `status` tags.
// Fields match documented LMS tag names: T=samplerate, I=samplesize, o=type,
// r=bitrate, Q=lossless, u=url, x=remote, X=album_replay_gain, Y=replay_gain.
//
// NOTE: LMSAudioQuality is referenced from PlayerViewModel.swift — do not move.

struct LMSAudioQuality {
    let sampleRate: Int
    let sampleSize: Int
    let type: String
    let bitrate: String?
    let lossless: Bool?
    let url: String?
    let remote: Bool?
    let replayGain: Double?
    let albumReplayGain: Double?
    let playerName: String?
    let playerMode: String?
    let lmsVolume: Int?
    let streamSampleRate: Int?
    let streamBitDepth: Int?
    let streamBitRate: String?
    let outputDeviceName: String?
    let rawTrackFields: [String: String]
    let rawStatusFields: [String: String]
    let fieldsUsed: [String]
    let missingFields: [String]
    let statusMatchedCurrentTrack: Bool?

    var detailSubtitle: String {
        var parts: [String] = []
        let codec = type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !codec.isEmpty { parts.append(codec) }
        if sampleRate > 0 { parts.append(AudioSignalPath.formatSampleRate(sampleRate)) }
        if sampleSize > 0 { parts.append("\(sampleSize)-bit") }
        if let bitrate, !bitrate.isEmpty { parts.append(bitrate) }
        if let lossless { parts.append(lossless ? "lossless source" : "lossy source") }
        return parts.isEmpty ? "LMS metadata not reported" : parts.joined(separator: " / ")
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {

    @ObservedObject private var player     = PlayerViewModel.shared
    @ObservedObject private var likedTracks = LikedTracksStore.shared
    @ObservedObject private var orpheus        = OrpheusDSPEngine.shared
    @ObservedObject private var profileManager = PlaybackProfileManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showSignalPath:    Bool = false
    @State private var showQueuePanel:    Bool = false
    @State private var showLyrics:        Bool = false
    @State private var showAddToPlaylist: Bool = false
    @State private var isDraggingProgress: Bool = false
    @State private var dragProgress:      Double = 0
    @State private var isPillPulsing:     Bool = false
    @State private var showProfileSheet:  Bool = false

    // MARK: - Derived

    private var signalPath: AudioSignalPath {
        guard let track = player.currentTrack else { return .mockPath }
        return AudioSignalPath.fromPlaybackState(
            track:             track,
            sourceFormat:      player.sourceFormat,
            selectedStreamURL: player.currentStreamURL,
            outputFormat:      player.outputFormat,
            outputDeviceName:  player.outputDeviceName,
            localVolume:       player.volume,
            lmsQuality:        player.lmsAudioQuality,
            orpheusState:      orpheus.signalPathState(
                isPlaybackRoutedThroughOrpheus: player.isPlaybackRoutedThroughOrpheus
            ),
            decodedFormat:     player.orpheusDecodedFormat,
            airPlayFallback:   player.orpheusFallbackReason?.contains("AirPlay") == true
                                   && !player.isPlaybackRoutedThroughOrpheus
        )
    }

    private var qualityPillInfo: (label: String, dotColor: Color, shouldPulse: Bool) {
        let path = signalPath
        return (path.badgeLabel, path.worstStatus.tintColor, path.isVerifiedBitPerfect)
    }

    private var effectiveDuration: Double {
        player.duration > 0 ? player.duration : (player.currentTrack?.duration ?? 0)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    headerBar
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    artworkSection
                        .padding(.top, 20)

                    trackInfo
                        .padding(.horizontal, 24)
                        .padding(.top, 20)

                    progressSection
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    transportControls
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    bottomToolbar
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                }
            }
            .simultaneousGesture(
                DragGesture()
                    .onEnded { if $0.translation.height > 80 { dismiss() } }
            )

            if showQueuePanel {
                queuePanelOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showSignalPath) {
            AudioSignalPathView(path: signalPath)
        }
        .fullScreenCover(isPresented: $showLyrics) {
            if let track = player.currentTrack {
                LyricsView(track: track)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(tracks: [track])
                    .environment(\.hyperionBottomOverlayHeight, 0)
            }
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileQuickSettingsSheet(profileManager: profileManager, player: player)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.36, dampingFraction: 0.80), value: showQueuePanel)
        .onAppear { isPillPulsing = true }
        .onChange(of: player.currentTrack?.id) { _, _ in
            isDraggingProgress = false
            dragProgress       = 0
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        FlatTintBackground(coverid: player.currentTrack?.coverid ?? "")
    }

    // MARK: - Header bar

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
                    label:         qualityPillInfo.label,
                    dotColor:      qualityPillInfo.dotColor,
                    isAnimating:   qualityPillInfo.shouldPulse,
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

    private var artworkSection: some View {
        // Side length = screen width minus 24 pt padding on each side.
        // ArtworkView's internal .frame(width:height:) needs an explicit point value;
        // GeometryReader inside a ScrollView can report 0 on first pass and causes
        // unconstrained-height artifacts, so we derive size from the window scene's
        // screen (non-deprecated replacement for UIScreen.main.bounds.width).
        let screenWidth = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390
        let side = screenWidth - 48
        return ArtworkView(
            coverid:     player.currentTrack?.coverid,
            size:        side,
            contentMode: .fit          // .fit never zooms or crops
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(.horizontal, 24)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        .id(player.currentTrack?.id ?? -1)
    }

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(player.currentTrack?.title ?? "")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.roonPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .center)

            let artistLine = player.currentTrack?.composer
                ?? player.currentTrack?.albumartist
                ?? player.currentTrack?.trackartist
                ?? ""
            if !artistLine.isEmpty {
                Text(artistLine)
                    .font(.system(size: 16))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if player.currentTrack != nil {
                Button {
                    Haptics.light()
                    showProfileSheet = true
                } label: {
                    Text(profileManager.pillLabel(profile: profileManager.activeProfile,
                                                  source: profileManager.detectionSource))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playback profile: \(profileManager.activeProfile.displayName). Tap to adjust.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let displayProgress = isDraggingProgress ? dragProgress : player.progress
                let clamped = max(0, min(1, displayProgress))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: width * CGFloat(clamped), height: 4)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: width * CGFloat(clamped) - 8)
                        .scaleEffect(isDraggingProgress ? 1.25 : 1.0)
                        .animation(.spring(response: 0.2), value: isDraggingProgress)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDraggingProgress { Haptics.light() }
                            isDraggingProgress = true
                            dragProgress = max(0, min(1, Double(value.location.x / width)))
                        }
                        .onEnded { _ in
                            player.seek(to: dragProgress * max(effectiveDuration, 1))
                            isDraggingProgress = false
                        },
                    including: .all
                )
            }
            .frame(height: 20)

            HStack {
                let displayTime = isDraggingProgress
                    ? dragProgress * effectiveDuration
                    : player.currentTime
                Text(formatTime(displayTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTime(effectiveDuration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                Haptics.light()
                player.cycleRepeat()
            } label: {
                Image(systemName: player.repeatMode == 1 ? "repeat.1" : "repeat")
                    .font(.system(size: 20))
                    .opacity(player.repeatMode > 0 ? 1.0 : 0.45)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.repeatMode == 0 ? "Repeat off" : player.repeatMode == 1 ? "Repeat one" : "Repeat all")
            Spacer()
            Button {
                Haptics.light()
                player.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous track")
            Spacer()
            Button {
                Haptics.medium()
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().tint(.white).scaleEffect(1.4)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44))
                    }
                }
                .frame(width: 76, height: 76)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isLoading ? "Loading" : (player.isPlaying ? "Pause" : "Play"))
            Spacer()
            Button {
                Haptics.light()
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next track")
            Spacer()
            Button {
                Haptics.light()
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .opacity(player.isShuffle ? 1.0 : 0.45)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isShuffle ? "Shuffle on" : "Shuffle off")
            Spacer()
        }
        .foregroundColor(.white)
        .frame(height: 80)
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            BottomToolbarButton(systemName: "line.3.horizontal", accessibilityLabel: "Queue") {
                Haptics.light()
                withAnimation { showQueuePanel = true }
            }
            Spacer(minLength: 0)
            BottomToolbarButton(
                systemName: likedTracks.isLiked(player.currentTrack) ? "heart.fill" : "heart",
                tint:       likedTracks.isLiked(player.currentTrack) ? .red : .white.opacity(0.36),
                accessibilityLabel: likedTracks.isLiked(player.currentTrack) ? "Unlike" : "Like"
            ) {
                Haptics.light()
                if let track = player.currentTrack {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
                        likedTracks.toggle(track)
                    }
                }
            }
            Spacer(minLength: 0)
            BottomToolbarButton(
                systemName: "slider.horizontal.3",
                tint: .white.opacity(0.36),
                accessibilityLabel: "Playback profile"
            ) {
                Haptics.light()
                showProfileSheet = true
            }
            Spacer(minLength: 0)
            BottomToolbarButton(
                systemName: "plus.circle",
                tint: .white.opacity(0.36),
                accessibilityLabel: "Add to playlist"
            ) {
                Haptics.light()
                showAddToPlaylist = true
            }
            .disabled(player.currentTrack == nil)
            Spacer(minLength: 0)
            BottomToolbarButton(
                systemName: "quote.bubble",
                tint: .white.opacity(0.36),
                accessibilityLabel: "Lyrics"
            ) {
                Haptics.light()
                showLyrics = true
            }
        }
    }

    // MARK: - Queue panel overlay

    private var queuePanelOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showQueuePanel = false } }

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
            .containerRelativeFrame(.vertical) { h, _ in max(h * 0.65, 300) }
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
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        TimeFormatting.formatDuration(seconds, placeholder: "0:00")
    }
}

// MARK: - Top chrome button

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
                .background(Circle().fill(Color.black.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Quality pill

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
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        )
    }
}

// MARK: - Bottom toolbar button

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

// MARK: - AirPlay button

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

// MARK: - Blurred album art background

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
                    .blur(radius: 70)
                    .scaleEffect(1.5)
                    .saturation(0.7)
                    .drawingGroup()
            } else {
                Color.roonBase
            }
        }
        .overlay(Color.black.opacity(0.60))
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

// MARK: - Inline work group row (queue panel)

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
                        .font(.roonBody(13, weight: item.index == player.currentIndex ? .semibold : .regular))
                        .foregroundColor(
                            item.index == player.currentIndex ? .roonAccent :
                            item.index  < player.currentIndex ? .roonTertiary : .roonSecondary
                        )
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

// MARK: - Profile quick settings sheet

private struct ProfileQuickSettingsSheet: View {
    @ObservedObject var profileManager: PlaybackProfileManager
    @ObservedObject var player: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Profile").foregroundColor(.roonPrimary)
                        Spacer()
                        Picker("Profile", selection: profilePickerBinding) {
                            ForEach(PlaybackProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.roonAccent)
                    }

                    if profileManager.detectionSource != .globalDefault {
                        Button("Reset to auto-detect") {
                            profileManager.clearManualOverride(for: player.currentTrack)
                            profileManager.update(for: player.currentTrack)
                        }
                        .font(.roonBody(13))
                        .foregroundColor(.roonAccent)
                    }
                } header: {
                    Text("PROFILE")
                } footer: {
                    Text(profileManager.pillLabel(
                        profile: profileManager.activeProfile,
                        source:  profileManager.detectionSource
                    ))
                    .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Toggle(isOn: gaplessBinding) {
                        Text("Gapless Playback").foregroundColor(.roonPrimary)
                    }
                    .tint(.roonAccent)

                    Toggle(isOn: crossfadeBinding) {
                        Text("Crossfade").foregroundColor(.roonPrimary)
                    }
                    .tint(.roonAccent)

                    if profileManager.resolvedCrossfadeEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Duration").font(.roonBody(13)).foregroundColor(.roonSecondary)
                                Spacer()
                                Text(String(format: "%.1f s", profileManager.resolvedCrossfadeDuration))
                                    .font(.roonBody(13)).foregroundColor(.roonTertiary).monospacedDigit()
                            }
                            Slider(value: cfDurationBinding, in: 0.5...12, step: 0.5)
                                .tint(.roonAccent)
                        }
                        .padding(.vertical, 2)
                    }

                    Toggle(isOn: crossfeedBinding) {
                        Text("Crossfeed (BS2B)").foregroundColor(.roonPrimary)
                    }
                    .tint(.roonAccent)

                    if profileManager.resolvedCrossfeedEnabled {
                        Picker("Preset", selection: crossfeedPresetBinding) {
                            ForEach(CrossfeedPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .foregroundColor(.roonSecondary)
                    }
                } header: {
                    Text("QUICK SETTINGS (THIS SESSION)")
                } footer: {
                    Text("Changes apply to the current session only. Permanent profile defaults are in Settings → Playback Profiles.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Playback Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.roonBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.roonAccent)
                        .fontWeight(.semibold)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var profilePickerBinding: Binding<PlaybackProfile> {
        Binding(
            get: { profileManager.activeProfile },
            set: { profile in profileManager.setManualOverride(profile, for: player.currentTrack) }
        )
    }

    private var gaplessBinding: Binding<Bool> {
        Binding(
            get: { profileManager.resolvedGaplessEnabled },
            set: { profileManager.sessionGaplessEnabled = $0 }
        )
    }

    private var crossfadeBinding: Binding<Bool> {
        Binding(
            get: { profileManager.resolvedCrossfadeEnabled },
            set: { profileManager.sessionCrossfadeEnabled = $0 }
        )
    }

    private var cfDurationBinding: Binding<Double> {
        Binding(
            get: { profileManager.resolvedCrossfadeDuration },
            set: { profileManager.sessionCrossfadeDuration = $0 }
        )
    }

    private var crossfeedBinding: Binding<Bool> {
        Binding(
            get: { profileManager.resolvedCrossfeedEnabled },
            set: { profileManager.sessionCrossfeedEnabled = $0 }
        )
    }

    private var crossfeedPresetBinding: Binding<CrossfeedPreset> {
        Binding(
            get: { profileManager.resolvedCrossfeedPreset },
            set: { profileManager.sessionCrossfeedPreset = $0 }
        )
    }
}
