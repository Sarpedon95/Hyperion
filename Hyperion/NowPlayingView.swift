import SwiftUI
import UIKit
import AVKit

// MARK: - LMS / Lyrion Audio Metadata
//
// Populated by PlayerViewModel from LMS `songinfo` and, when useful for
// diagnostics, `status`. The fields match documented LMS tag names:
//   T=samplerate, I=samplesize, o=type, r=bitrate, Q=lossless,
//   u=url, x=remote, X=album_replay_gain, Y=replay_gain.
//
// These values describe what LMS reports about the track/status. They do not
// by themselves prove the final output format, OS/device processing, or a
// bit-perfect path.

struct LMSAudioQuality {
    let sampleRate: Int        // Hz, 0 when not reported
    let sampleSize: Int        // bits, 0 when not reported
    let type: String           // codec/container string from LMS
    let bitrate: String?
    let lossless: Bool?
    let url: String?
    let remote: Bool?
    let replayGain: Double?
    let albumReplayGain: Double?
    let playerName: String?
    let playerMode: String?
    let lmsVolume: Int?
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
    @ObservedObject private var likedTracks = LikedTracksStore.shared
    @ObservedObject private var orpheus = OrpheusDSPEngine.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isDraggingProgress: Bool = false
    @State private var dragProgress: Double = 0

    @State private var showSignalPath: Bool = false
    @State private var showQueuePanel: Bool = false
    @State private var showMoreActions: Bool = false
    @State private var showAddToPlaylist: Bool = false
    @State private var showSleepTimer: Bool = false
    @ObservedObject private var sleepTimer = SleepTimerManager.shared

    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingDown: Bool = false

    @State private var isPillPulsing: Bool = false

    @State private var artworkDragOffset: CGFloat = 0
    @State private var artworkOpacity: Double = 1.0
    @State private var artworkTransitioning: Bool = false
    @State private var artworkSwipeTask: Task<Void, Never>? = nil
    @State private var showArtworkFullScreen: Bool = false

    @State private var ooWorkDetail: OOWorkDetailResponse? = nil
    @State private var showLyrics: Bool = false

    @State private var navPath = NavigationPath()
    @State private var showShareSheet: Bool = false
    @State private var showJournalSheet: Bool = false
    @State private var journalTrack: Track? = nil
    @State private var showOrpheus: Bool = false

    private var qualityPillInfo: (label: String, dotColor: Color, shouldPulse: Bool) {
        let path = signalPath
        return (path.badgeLabel, path.worstStatus.tintColor, path.isVerifiedBitPerfect)
    }

    private var signalPath: AudioSignalPath {
        guard let track = player.currentTrack else { return .mockPath }
        return AudioSignalPath.fromPlaybackState(
            track:             track,
            sourceFormat:      player.sourceFormat,
            selectedStreamURL: player.currentStreamURL,
            outputFormat:      player.outputFormat,
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


    var body: some View {
        NavigationStack(path: $navPath) {
        ZStack(alignment: .bottom) {
            backgroundLayer
                .ignoresSafeArea()
                .overlay(backgroundChrome)
                .opacity(isDraggingDown ? max(0.45, 1.0 - dragOffset / 260) : 1.0)

            GeometryReader { geo in
                let window = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                let safeTop = window?.safeAreaInsets.top ?? 59.0
                let safeBottom = window?.safeAreaInsets.bottom ?? 34.0
                let available = geo.size.height - safeTop - safeBottom
                let artworkSide = min(geo.size.width - 48, available * 0.38)
                let remaining = available - artworkSide - 44 - 60 - 44 - 80 - 60
                let gap = max(remaining / 4, 4)

                VStack(spacing: 0) {
                    headerBar.frame(height: 44)
                    artworkSection(side: artworkSide)
                    trackInfo.frame(height: 60).background(Color.blue)
                    Color.clear.frame(height: gap)
                    progressSection.frame(height: 44).background(Color.red)
                    Color.clear.frame(height: gap)
                    transportControls.frame(height: 80)
                    Color.clear.frame(height: gap)
                    bottomToolbar.frame(height: 60)
                    Color.clear.frame(height: gap)
                }
                .frame(width: geo.size.width)
                .padding(.top, safeTop)
                .padding(.bottom, safeBottom)
                .simultaneousGesture(swipeDownToDismissGesture)
            }
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .animation(isDraggingDown ? .none : .spring(response: 0.34, dampingFraction: 0.84), value: dragOffset)

            if showQueuePanel {
                queuePanelOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) { debugOverlay }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showSignalPath) {
            AudioSignalPathView(path: signalPath)
        }
        .fullScreenCover(isPresented: $showLyrics) {
            if let track = player.currentTrack {
                LyricsView(track: track)
            }
        }
        .fullScreenCover(isPresented: $showArtworkFullScreen) {
            ArtworkFullScreenView(coverid: player.currentTrack?.coverid)
        }
        .confirmationDialog("Now Playing", isPresented: $showMoreActions, titleVisibility: .visible) {
            Button("Sleep Timer") {
                Haptics.light()
                showSleepTimer = true
            }
            Button(player.isRadioEnabled ? "Radio Off" : "Radio On") {
                Haptics.light()
                player.isRadioEnabled.toggle()
            }
            Button(FocusMode.shared.isActive ? "Deactivate Focus Mode" : "Focus Mode") {
                Haptics.medium()
                FocusMode.shared.toggle(currentTrack: player.currentTrack)
            }
            Button("Lyrics") {
                Haptics.light()
                showLyrics = true
            }
            Button("Signal Path") {
                Haptics.light()
                showSignalPath = true
            }
            if let track = player.currentTrack {
                Button("Play Next") {
                    Haptics.light()
                    player.playNext([track])
                }
                Button("Add to Playlist") {
                    Haptics.light()
                    showAddToPlaylist = true
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.80), value: showQueuePanel)
        .onAppear {
            isPillPulsing = true
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            isDraggingProgress = false
            dragProgress = 0
            artworkDragOffset = 0
            artworkOpacity = 1.0
            artworkSwipeTask?.cancel()
            artworkSwipeTask = nil
            artworkTransitioning = false
            ooWorkDetail = nil
            if !navPath.isEmpty { navPath = NavigationPath() }
        }
        .onDisappear {
            artworkSwipeTask?.cancel()
        }
        .task(id: player.currentTrack?.id) {
            await fetchOOWorkDetail()
            await prewarmArtistDetail()
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(tracks: [track])
                    .environment(\.hyperionBottomOverlayHeight, 0)
            }
        }
        .confirmationDialog("Sleep Timer", isPresented: $showSleepTimer, titleVisibility: .visible) {
            if sleepTimer.isActive {
                Button("Turn Off", role: .destructive) { sleepTimer.cancel() }
            }
            Button("End of Track") { sleepTimer.set(mode: .endOfTrack) }
            ForEach(SleepTimerManager.minuteOptions, id: \.self) { minutes in
                Button("\(minutes) min") { sleepTimer.set(mode: .minutes(minutes)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if sleepTimer.isActive {
                if case .endOfTrack = sleepTimer.mode {
                    Text("Stops after current track")
                } else {
                    let mins = Int(sleepTimer.timeRemaining / 60)
                    let secs = Int(sleepTimer.timeRemaining) % 60
                    Text(String(format: "%d:%02d remaining", mins, secs))
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let track = player.currentTrack {
                ShareSheet(items: [HyperionShare.nowPlayingText(track: track)])
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showJournalSheet) {
            if let track = journalTrack {
                JournalEntrySheet(track: track)
            }
        }
        .onChange(of: player.currentTrack?.id) { oldID, newID in
            // Offer the journal when the track advances, if the user enabled prompts.
            guard UserDefaults.standard.bool(forKey: "hyperion.journal.promptEnabled"),
                  let oldID, oldID != newID, !showJournalSheet else { return }
            if let finished = player.queue.first(where: { $0.id == oldID }) {
                journalTrack    = finished
                showJournalSheet = true
            }
        }
        .sheet(isPresented: $showOrpheus) {
            OrpheusView()
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Artist.self) { artist in
            ArtistDetailView(artist: artist)
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        } // NavigationStack
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
        FlatTintBackground(coverid: player.currentTrack?.coverid ?? "")
    }

    private var backgroundChrome: some View {
        // ARC-style: very subtle top vignette only
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.black.opacity(0.10), location: 0.0),
                .init(color: Color.clear, location: 0.15)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
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
                    isAnimating: qualityPillInfo.shouldPulse,
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
            Color.black.opacity(0.4)
            ArtworkView(
                coverid: player.currentTrack?.coverid,
                size: side,
                contentMode: .fill
            )
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        .offset(x: artworkDragOffset)
        .opacity(artworkOpacity)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .gesture(artworkSwipeGesture)
        .onTapGesture { showArtworkFullScreen = true }
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

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(alignment: .center, spacing: 6) {
            Button {
                if let album = resolvedAlbum() {
                    Haptics.light()
                    navPath.append(album)
                }
            } label: {
                Text(player.currentTrack?.title ?? "")
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundColor(.roonPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .disabled(resolvedAlbum() == nil)

            let artistLine = player.currentTrack?.composer
                ?? player.currentTrack?.albumartist
                ?? player.currentTrack?.trackartist
                ?? ""
            if !artistLine.isEmpty {
                Button {
                    Haptics.light()
                    navPath.append(resolvedArtist(named: artistLine))
                } label: {
                    Text(artistLine)
                        .font(.system(size: 16, weight: .regular, design: .default))
                        .foregroundColor(.roonSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func resolvedArtist(named name: String) -> Artist {
        LibraryViewModel.shared.artists.first { $0.name == name }
            ?? Artist(id: 0, name: name)
    }

    private func resolvedAlbum() -> Album? {
        guard let track = player.currentTrack else { return nil }
        // Try the in-memory library first (fast path).
        if let albumID = track.albumID,
           let found = LibraryViewModel.shared.albums.first(where: { $0.id == albumID }) {
            return found
        }
        // Fallback: construct a lightweight Album from track metadata so the
        // album screen still opens even when the library hasn't been fully loaded.
        guard let albumName = track.album, !albumName.isEmpty else { return nil }
        return Album(
            id:               track.albumID ?? 0,
            album:            albumName,
            artist:           track.albumartist ?? track.trackartist,
            year:             track.year,
            artwork_track_id: track.coverid,
            composer:         track.composer,
            isClassical:      track.isClassical
        )
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 8) {
            // Use the segmented scrubber when the current track is part of a
            // multi-movement work and the queue contains all those movements.
            if let group = player.currentWorkGroup,
               group.tracks.count > 1,
               let currentID = player.currentTrack?.id,
               group.tracks.contains(where: { $0.id == currentID }) {
                SegmentedScrubberView(
                    group:           group,
                    currentTrackID:  currentID,
                    progress:        player.progress,
                    currentTime:     player.currentTime,
                    duration:        player.duration > 0 ? player.duration : (player.currentTrack?.duration ?? 0),
                    isDragging:      $isDraggingProgress,
                    dragProgress:    $dragProgress,
                    queue:           player.queue
                ) { fraction in
                    player.seek(to: fraction * max(player.duration, 1))
                } onJumpToMovement: { queueIndex in
                    Haptics.light()
                    player.playTrack(at: queueIndex)
                }
            } else {
                ProgressBarView(
                    progress:     player.progress,
                    isDragging:   $isDraggingProgress,
                    dragProgress: $dragProgress
                ) { finalProgress in
                    player.seek(to: finalProgress * max(player.duration, 1))
                }
                .frame(height: 22)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatTime(player.currentTime)) of \(formatTime(player.duration))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: player.seek(to: min(player.currentTime + 10, player.duration))
                    case .decrement: player.seek(to: max(player.currentTime - 10, 0))
                    @unknown default: break
                    }
                }

                HStack {
                    let effectiveDuration = player.duration > 0
                        ? player.duration
                        : (player.currentTrack?.duration ?? 0)
                    let displayTime = isDraggingProgress
                        ? dragProgress * effectiveDuration
                        : player.currentTime
                    let remaining = max(0, effectiveDuration - displayTime)

                    Text(formatTime(displayTime))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                        .monospacedDigit()

                    Spacer()

                    Text("-\(formatTime(remaining))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        HStack(spacing: 0) {
            // Repeat — flanking control, 20pt
            SmallTransportButton(
                systemName: repeatIcon,
                isActive: player.repeatMode > 0,
                accessibilityLabel: repeatAccessibilityLabel
            ) {
                Haptics.light()
                player.cycleRepeat()
            }

            Spacer(minLength: 0)

            // Previous track — skip button
            MainTransportButton(systemName: "backward.end.fill", size: 24, accessibilityLabel: "Previous track") {
                Haptics.light()
                player.previousTrack()
            }

            Spacer(minLength: 0)

            // Play / Pause — large center button
            Button {
                Haptics.medium()
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.4)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundColor(.roonPrimary)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
                .frame(width: 76, height: 76)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .scaleEffect(player.isPlaying ? 1.0 : 0.97)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: player.isPlaying)
            .accessibilityLabel(player.isLoading ? "Loading" : (player.isPlaying ? "Pause" : "Play"))

            Spacer(minLength: 0)

            // Next track — skip button
            MainTransportButton(systemName: "forward.end.fill", size: 24, accessibilityLabel: "Next track") {
                Haptics.light()
                player.nextTrack()
            }

            Spacer(minLength: 0)

            // Shuffle — flanking control, 20pt
            SmallTransportButton(
                systemName: "shuffle",
                isActive: player.isShuffle,
                accessibilityLabel: player.isShuffle ? "Shuffle on" : "Shuffle off"
            ) {
                Haptics.light()
                player.toggleShuffle()
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

    // MARK: - Bottom toolbar (5 buttons: queue · heart · share · DSP · more)

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // Queue
            BottomToolbarButton(systemName: "line.3.horizontal", accessibilityLabel: "Queue") {
                Haptics.light()
                withAnimation { showQueuePanel = true }
            }

            Spacer(minLength: 0)

            // Like / heart
            BottomToolbarButton(
                systemName: likedTracks.isLiked(player.currentTrack) ? "heart.fill" : "heart",
                tint: likedTracks.isLiked(player.currentTrack) ? .red : .roonSecondary,
                accessibilityLabel: likedTracks.isLiked(player.currentTrack) ? "Unlike" : "Like"
            ) {
                Haptics.light()
                if let track = player.currentTrack {
                    let wasLiked = likedTracks.isLiked(track)
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
                        likedTracks.toggle(track)
                    }
                    let lfm = LastFmAuthManager.shared
                    if lfm.isSignedIn {
                        if wasLiked {
                            lfm.unlove(track: track.title ?? "", artist: track.trackartist ?? track.albumartist ?? "")
                        } else {
                            lfm.love(track: track.title ?? "", artist: track.trackartist ?? track.albumartist ?? "")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Share
            BottomToolbarButton(systemName: "square.and.arrow.up", accessibilityLabel: "Share") {
                Haptics.light()
                showShareSheet = true
            }

            Spacer(minLength: 0)

            // DSP / EQ
            BottomToolbarButton(
                systemName: "dial.medium",
                tint: .roonSecondary,
                accessibilityLabel: "DSP"
            ) {
                Haptics.light()
                showOrpheus = true
            }

            Spacer(minLength: 0)

            // More (ellipsis) — includes sleep timer, radio, signal path, focus mode
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

    // MARK: - OpenOpus work info

    @ViewBuilder
    private func openOpusInfoBlock(detail: OOWorkDetailResponse) -> some View {
        if let work = detail.work {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.36))
                    Text("OPEN OPUS")
                        .font(.roonBody(10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.36))
                        .kerning(1.2)
                }

                Text(work.title)
                    .font(.roonBody(13))
                    .foregroundColor(.white.opacity(0.64))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if let genre = work.genre, !genre.isEmpty {
                        Text(genre)
                            .font(.roonBody(10, weight: .medium))
                            .foregroundColor(.roonAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.roonAccent.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    if let performers = detail.performers, !performers.isEmpty {
                        let names = performers.prefix(2).map(\.name).joined(separator: " · ")
                        Text(names)
                            .font(.roonBody(10))
                            .foregroundColor(.white.opacity(0.44))
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func fetchOOWorkDetail() async {
        guard let track = player.currentTrack else {
            ooWorkDetail = nil
            return
        }
        let title: String
        if let w = track.work, !w.isEmpty { title = w }
        else if let a = track.album, !a.isEmpty { title = a }
        else { title = track.title }
        let composer = track.composer ?? track.albumartist ?? ""
        guard !composer.isEmpty else {
            ooWorkDetail = nil
            return
        }
        // Keep old detail visible while fetching — prevents flash on track change.
        guard let result = await LMSLibraryLinker.shared.guessWork(title: title,
                                                                    composerName: composer),
              let workID = result.guessed?.id else {
            ooWorkDetail = nil
            return
        }
        do {
            ooWorkDetail = try await OpenOpusService.shared.workDetail(workID)
        } catch {
            linkerLog("NowPlaying workDetail failed for workID \(workID): \(error)")
            ooWorkDetail = nil
        }
    }

    private func prewarmArtistDetail() async {
        guard let track = player.currentTrack else {
            print("[Prewarm] No current track — skipping")
            return
        }
        let library = LibraryViewModel.shared
        print("[Prewarm] Track loaded: '\(track.title)' — starting prewarm")

        // Load artists list if empty, so resolvedArtist() can find a valid id.
        if library.artists.isEmpty {
            print("[Prewarm] Artists list empty — loading now")
            await library.loadArtists()
        }

        let name = track.composer ?? track.albumartist ?? track.trackartist ?? ""
        guard !name.isEmpty else {
            print("[Prewarm] No artist name on track — skipping")
            return
        }
        guard let artist = library.artists.first(where: { $0.name == name }), artist.id > 0 else {
            print("[Prewarm] Artist '\(name)' not found in library (id=0 or missing) — skipping")
            return
        }

        print("[Prewarm] Pre-warming artist detail for '\(name)' (id=\(artist.id))")
        _ = try? await library.loadArtistDetail(artistID: artist.id)
        print("[Prewarm] Done — artist detail cached for '\(name)'")
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
        .buttonStyle(ScaleButtonStyle(scale: 0.92))
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
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
            let thumbOffset = max(0, min(width - 16, filledWidth - 8))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)

                Capsule()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: max(0, filledWidth), height: 3)

                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.35), radius: 4)
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
                    .blur(radius: 120)
                    .scaleEffect(2.0)
                    .saturation(0.4)
                    .brightness(-0.28)
                    .hueRotation(.degrees(50)) // shift toward green/olive
                    .drawingGroup()
            } else {
                Color.roonBase
            }
        }
        .overlay(Color(hex: "#1a1e14").opacity(0.55))
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

// MARK: - Full-screen artwork viewer (pinch-to-zoom, drag-to-dismiss, share)

private struct ArtworkFullScreenView: View {
    let coverid: String?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @GestureState private var liveScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var dismissOffset: CGFloat = 0
    @State private var showShare = false
    @State private var shareImage: UIImage? = nil

    private var effectiveScale: CGFloat { min(max(scale * liveScale, 1.0), 4.0) }
    private var isZoomed: Bool { scale > 1.05 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(1.0 - Double(max(dismissOffset, 0)) / 350.0)

            GeometryReader { geo in
                ArtworkView(coverid: coverid, size: geo.size.width)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(effectiveScale)
                    .offset(x: panOffset.width, y: panOffset.height + dismissOffset)
                    .gesture(zoomGesture)
                    .gesture(combinedDragGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            if isZoomed { scale = 1.0; panOffset = .zero }
                            else { scale = 2.0 }
                        }
                    }
            }

            VStack {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        fetchAndShare()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 60)
                .opacity(1.0 - Double(max(dismissOffset, 0)) / 180.0)
                Spacer()
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShare) {
            if let img = shareImage { ShareSheet(items: [img]) }
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($liveScale) { value, state, _ in state = value }
            .onEnded { value in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    scale = min(max(scale * value, 1.0), 4.0)
                    if scale <= 1.0 { scale = 1.0; panOffset = .zero }
                }
            }
    }

    private var combinedDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if isZoomed {
                    panOffset = CGSize(
                        width: panStart.width + value.translation.width,
                        height: panStart.height + value.translation.height
                    )
                } else if value.translation.height > 0 {
                    dismissOffset = value.translation.height * 0.72
                }
            }
            .onEnded { value in
                if isZoomed {
                    panStart = panOffset
                } else {
                    if value.translation.height > 80 || value.predictedEndTranslation.height > 150 {
                        Haptics.light()
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            dismissOffset = 0
                        }
                    }
                }
            }
    }

    private func fetchAndShare() {
        guard let cid = coverid, !cid.isEmpty else { return }
        Task {
            let img = await ArtworkCache.shared.loadImage(coverid: cid, targetPoints: 512, scale: 1)
            await MainActor.run {
                shareImage = img
                if shareImage != nil { showShare = true }
            }
        }
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

// MARK: - Movement-level segmented scrubber

/// Replaces the standard progress bar when the current track belongs to a
/// multi-movement work. Each segment represents one movement, width
/// proportional to its duration. The active segment is draggable for
/// within-movement scrubbing; tapping another segment jumps to it.
struct SegmentedScrubberView: View {
    let group: WorkGroup
    let currentTrackID: Int
    let progress: Double        // 0–1 within the current movement
    let currentTime: Double     // seconds elapsed in current movement
    let duration: Double        // duration of current movement
    @Binding var isDragging: Bool
    @Binding var dragProgress: Double
    let queue: [Track]
    let onSeekInMovement: (Double) -> Void
    let onJumpToMovement: (Int) -> Void

    init(group: WorkGroup,
         currentTrackID: Int,
         progress: Double,
         currentTime: Double,
         duration: Double,
         isDragging: Binding<Bool>,
         dragProgress: Binding<Double>,
         queue: [Track],
         onSeekInMovement: @escaping (Double) -> Void,
         onJumpToMovement: @escaping (Int) -> Void) {
        self.group = group
        self.currentTrackID = currentTrackID
        self.progress = progress
        self.currentTime = currentTime
        self.duration = duration
        self._isDragging = isDragging
        self._dragProgress = dragProgress
        self.queue = queue
        self.onSeekInMovement = onSeekInMovement
        self.onJumpToMovement = onJumpToMovement
    }

    private var totalDuration: Double {
        group.tracks.compactMap(\.duration).reduce(0, +)
    }

    private var currentMovementIndex: Int {
        group.tracks.firstIndex(where: { $0.id == currentTrackID }) ?? 0
    }

    private var currentMovement: Track? {
        group.tracks.first(where: { $0.id == currentTrackID })
    }

    private func queueIndex(for track: Track) -> Int? {
        queue.firstIndex(where: { $0.id == track.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Movement name
            if let movement = currentMovement {
                Text(movement.title)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(1)
                    .transition(.opacity)
                    .id(movement.id)
            }

            // Segmented bar
            GeometryReader { geo in
                let total = max(totalDuration, 1)
                let gap: CGFloat = 3
                let gapTotal = gap * CGFloat(group.tracks.count - 1)
                let barWidth = max(0, geo.size.width - gapTotal)

                HStack(spacing: gap) {
                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { idx, track in
                        let movDur = max(track.duration ?? 1, 1)
                        let segWidth = max(4, barWidth * CGFloat(movDur / total))
                        let isCurrent = track.id == currentTrackID
                        let isPast = idx < currentMovementIndex

                        SegmentView(
                            width:      segWidth,
                            isCurrent:  isCurrent,
                            isPast:     isPast,
                            progress:   isCurrent ? (isDragging ? dragProgress : progress) : (isPast ? 1.0 : 0.0),
                            isDragging: isCurrent ? isDragging : false
                        )
                        .frame(width: segWidth, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isCurrent, let qi = queueIndex(for: track) else { return }
                            onJumpToMovement(qi)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .onChanged { v in
                                    guard isCurrent else { return }
                                    if !isDragging { Haptics.light() }
                                    isDragging   = true
                                    dragProgress = max(0, min(1, v.location.x / segWidth))
                                }
                                .onEnded { _ in
                                    guard isCurrent else { return }
                                    onSeekInMovement(dragProgress)
                                    isDragging = false
                                }
                        )
                    }
                }
            }
            .frame(height: 22)

            // Time labels
            HStack {
                let displayTime = isDragging ? dragProgress * max(duration, 1) : currentTime
                Text(formatMovTime(displayTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .monospacedDigit()

                Spacer()

                // Show mvt remaining / total work
                let movRemaining = max(0, duration - (isDragging ? dragProgress * max(duration, 1) : currentTime))
                Text("-\(formatMovTime(movRemaining))  /  \(formatMovTime(totalDuration))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .monospacedDigit()
            }
        }
    }

    private func formatMovTime(_ t: Double) -> String {
        TimeFormatting.formatDuration(t, placeholder: "—")
    }
}

// MARK: - Inline synced lyrics (embedded below transport controls)

private struct InlineLyricsSection: View {
    let track: Track
    @ObservedObject private var player = PlayerViewModel.shared

    struct ILDLine: Identifiable {
        let id: UUID
        let text: String
        let time: TimeInterval
        let isInterlude: Bool
    }

    @State private var displayLines: [ILDLine] = []
    @State private var plainText: String? = nil
    @State private var activeIndex: Int = 0

    var body: some View {
        Group {
            if !displayLines.isEmpty {
                syncedView
                    .frame(height: 200)
            } else if let plain = plainText, !plain.isEmpty {
                Text(plain)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.32))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
            }
            // unavailable → zero height, no space taken
        }
        .task(id: track.id) { await load() }
        .onChange(of: player.currentTime) { _, t in updateActive(t) }
    }

    @ViewBuilder
    private var syncedView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 64)
                    ForEach(Array(displayLines.enumerated()), id: \.element.id) { idx, line in
                        let dist = abs(idx - activeIndex)
                        let isActive = dist == 0
                        let opacity: Double = isActive ? 1.0 : dist == 1 ? 0.42 : dist == 2 ? 0.22 : 0.10
                        Text(line.text)
                            .font(isActive
                                  ? .system(size: 15, weight: .semibold)
                                  : .system(size: 14, weight: .regular))
                            .foregroundColor(.white.opacity(opacity))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.vertical, isActive ? 7 : 4)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                            .animation(.easeOut(duration: 0.18), value: activeIndex)
                            .onTapGesture {
                                guard !line.isInterlude else { return }
                                player.seek(to: line.time)
                            }
                    }
                    Color.clear.frame(height: 64)
                }
            }
            .onChange(of: activeIndex) { _, idx in
                guard idx < displayLines.count else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(displayLines[idx].id, anchor: .center)
                }
            }
            .onAppear {
                updateActive(player.currentTime)
                if activeIndex < displayLines.count {
                    proxy.scrollTo(displayLines[activeIndex].id, anchor: .center)
                }
            }
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.13),
                .init(color: .black, location: 0.87),
                .init(color: .clear, location: 1.0)
            ], startPoint: .top, endPoint: .bottom)
        )
        .allowsHitTesting(true)
    }

    private func updateActive(_ time: TimeInterval) {
        let adj = time + 0.3
        var result = 0
        for (i, line) in displayLines.enumerated() {
            if line.time <= adj { result = i } else { break }
        }
        if result != activeIndex { activeIndex = result }
    }

    private func load() async {
        displayLines = []
        plainText    = nil
        activeIndex  = 0

        let cached = LyricsService.shared.cachedResult(trackID: track.id)
        let result: LyricsResult
        if let cached {
            result = cached
        } else {
            let artist = track.composer ?? track.albumartist ?? track.trackartist ?? ""
            let title  = track.work.flatMap { $0.isEmpty ? nil : $0 } ?? track.title
            result = await LyricsService.shared.lyrics(
                artistName: artist.isEmpty ? (track.albumartist ?? track.title) : artist,
                trackName:  title,
                albumName:  (track.album?.isEmpty == false) ? track.album : nil,
                duration:   (track.duration ?? 0) > 0 ? track.duration : nil,
                trackID:    track.id
            )
        }

        switch result {
        case .synced(let lines):
            let built = buildDisplayLines(lines)
            withAnimation(.easeIn(duration: 0.2)) { displayLines = built }
        case .plain(let text):
            withAnimation { plainText = text }
        default:
            break
        }
    }

    private func buildDisplayLines(_ lines: [LyricsLine]) -> [ILDLine] {
        var result: [ILDLine] = []
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let gap = line.time - lines[i - 1].time
                if gap > 8 {
                    result.append(ILDLine(id: UUID(), text: "• • •",
                                          time: lines[i - 1].time + gap / 2, isInterlude: true))
                }
            }
            let text = line.text.trimmingCharacters(in: .whitespaces)
            result.append(ILDLine(id: line.id, text: text.isEmpty ? "•" : text,
                                  time: line.time, isInterlude: false))
        }
        return result
    }
}

private struct SegmentView: View {
    let width: CGFloat
    let isCurrent: Bool
    let isPast: Bool
    let progress: Double
    let isDragging: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // Track (background)
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(height: isCurrent ? 4 : 3)

            // Fill
            Capsule()
                .fill(Color.white.opacity(isPast ? 0.55 : (isCurrent ? 0.95 : 0.20)))
                .frame(width: max(0, width * CGFloat(progress)), height: isCurrent ? 4 : 3)

            // Thumb on active segment
            if isCurrent {
                let thumbOffset = max(0, min(width - 16, width * CGFloat(progress) - 8))
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 4)
                    .offset(x: thumbOffset)
                    .scaleEffect(isDragging ? 1.2 : 1.0)
                    .animation(.spring(response: 0.2), value: isDragging)
            }
        }
        .frame(height: 22)
        .clipShape(Capsule())
    }
}
