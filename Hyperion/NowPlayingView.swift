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
    @State private var showInlineLyrics:  Bool = false
    @State private var inlineLyrics:      InlineLyricsState = .loading
    @State private var showRadioSession:  Bool = false
    @State private var showEQ:            Bool = false
    @State private var showMore:          Bool = false
    @State private var showFullLyrics:    Bool = false
    @State private var albumNavTarget:    Album? = nil
    @State private var artistNavTarget:   Artist? = nil
    @State private var showClassicalInfo: Bool = false

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
            // 1. BACKGROUND
            backgroundLayer
                .ignoresSafeArea()

            // 2. CONTENT — radio gets a dedicated live-stream layout; everything
            // else uses the standard track layout.
            if player.isPlayingRadio {
                radioNowPlayingContent
            } else {
                VStack(spacing: 0) {
                    headerBar
                        .padding(.horizontal, 8)
                        .padding(.top, 8)

                    artworkSection
                        .padding(.top, 20)

                    trackInfo
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    scrubberSection
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    if showLyrics {
                        InlineLyricsPanel(state: inlineLyrics, player: player) {
                            showFullLyrics = true
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if let group = player.currentWorkGroup, group.tracks.count > 1 {
                        WorkProgressBar(
                            group:          group,
                            currentTrackID: player.currentTrack?.id
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    Spacer(minLength: 0)

                    transportControls
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)

                    bottomToolbar
                        .padding(.bottom, 12)
                }
            }

            if showQueuePanel {
                queuePanelOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showSignalPath) {
            AudioSignalPathView(path: signalPath)
        }
        .fullScreenCover(isPresented: $showFullLyrics) {
            if let track = player.currentTrack {
                LyricsView(track: track)
            }
        }
        .sheet(isPresented: $showEQ) {
            ProfileQuickSettingsSheet(profileManager: profileManager, player: player)
        }
        .sheet(isPresented: $showMore) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(tracks: [track])
                    .environment(\.hyperionBottomOverlayHeight, 0)
            }
        }
        .sheet(item: $albumNavTarget) { album in
            NavigationStack { AlbumDetailView(album: album) }
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .sheet(item: $artistNavTarget) { artist in
            NavigationStack { ArtistDetailView(artist: artist) }
                .environment(\.hyperionBottomOverlayHeight, 0)
        }
        .sheet(isPresented: $showClassicalInfo) {
            if let metadata = player.currentTrack?.classicalMetadata {
                ClassicalInfoSheet(metadata: metadata)
                    .environment(\.hyperionBottomOverlayHeight, 0)
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: player.currentTrack?.id)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: player.isPlaying)
        .animation(.spring(response: 0.36, dampingFraction: 0.80), value: showQueuePanel)
        .onAppear { isPillPulsing = true }
        .onChange(of: player.currentTrack?.id) { _, _ in
            isDraggingProgress = false
            dragProgress       = 0
            inlineLyrics       = .loading
        }
        .task(id: player.currentTrack?.id) {
            guard let track = player.currentTrack else { inlineLyrics = .unavailable; return }
            if let cached = LyricsService.shared.cachedResult(trackID: track.id) {
                inlineLyrics = InlineLyricsState(from: cached)
                return
            }
            let artist = track.composer ?? track.albumartist ?? track.trackartist ?? track.title
            let title  = (track.work?.isEmpty == false ? track.work : nil) ?? track.title
            let result = await LyricsService.shared.lyrics(
                artistName: artist,
                trackName:  title,
                albumName:  track.album.flatMap { $0.isEmpty ? nil : $0 },
                duration:   (track.duration ?? 0) > 0 ? track.duration : nil,
                trackID:    track.id
            )
            inlineLyrics = InlineLyricsState(from: result)
        }
    }

    // MARK: - Radio Now Playing

    @ViewBuilder
    private var radioNowPlayingContent: some View {
        let station = player.currentRadioStation
        let side = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390) - 96

        VStack(spacing: 0) {
            HStack {
                TopChromeButton(systemName: "chevron.down", accessibilityLabel: "Close") {
                    Haptics.light(); dismiss()
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)   // balances the close button
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Spacer(minLength: 0)

            RadioLogoImage(url: station?.logoURL, size: side, fallbackInitials: station?.initials ?? "")
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)

            VStack(spacing: 8) {
                // LIVE badge
                Text("LIVE")
                    .font(.roonBody(11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red)
                    .clipShape(Capsule())

                Text(station?.name ?? "Radio")
                    .font(.roonTitle(24))
                    .foregroundColor(.roonPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                if let genre = station?.genre, !genre.isEmpty {
                    Text(genre)
                        .font(.roonBody(15))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }

                if let detail = radioDetailLine(station) {
                    Text(detail)
                        .font(.roonBody(12))
                        .foregroundColor(.roonTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer(minLength: 0)

            // Play / pause only — no scrubber, no skip controls.
            Button {
                if !player.isLoading { Haptics.medium() }
                player.togglePlayPause()
            } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().tint(.white).scaleEffect(1.4)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                }
                .frame(width: 80, height: 80)
                .contentShape(Rectangle())
            }
            .foregroundColor(.white)

            Button {
                Haptics.light()
                player.stopRadioStation()
                dismiss()
            } label: {
                Text("Stop")
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.roonAccent.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .padding(.bottom, 24)

            Spacer(minLength: 0)
        }
    }

    private func radioDetailLine(_ station: RadioStation?) -> String? {
        guard let station else { return nil }
        let parts = [station.country, station.bitrateDisplay].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

            // Centre column: quality pill + profile label stacked vertically.
            // FIXED: profile pill moved here from trackInfo so it sits in the
            // nav area, not between the artist name and the scrubber.
            VStack(spacing: 4) {
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

                // Radio LIVE badge (handled elsewhere) > stream source badge >
                // profile pill. Stream and profile are mutually exclusive — if
                // a stream track is playing, the stream pill replaces the
                // profile pill since profile only applies to local playback.
                if let streamTrack = player.currentStreamTrack {
                    StreamSourcePill(track: streamTrack)
                } else if player.currentTrack != nil {
                    Button {
                        Haptics.light()
                        showProfileSheet = true
                    } label: {
                        Text(profileManager.pillLabel(
                            profile: profileManager.activeProfile,
                            source:  profileManager.detectionSource
                        ))
                        .font(.roonBody(11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Playback profile: \(profileManager.activeProfile.displayName). Tap to adjust.")
                }

                if player.isRadioEnabled {
                    Button {
                        Haptics.light()
                        showRadioSession = true
                    } label: {
                        Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.roonAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.roonAccent.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Radio active. Tap to manage.")
                    .transition(.scale.combined(with: .opacity))
                }
            }

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
            contentMode: .fit
        )
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        .id(player.currentTrack?.id ?? -1)
        // fullScreenCover has no built-in swipe-to-dismiss; handle it on the
        // artwork only so it never conflicts with the scrubber's horizontal drag.
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { v in
                    let isDownward = v.translation.height > abs(v.translation.width)
                    if isDownward && v.translation.height > 80 {
                        Haptics.light()
                        dismiss()
                    }
                }
        )
    }

    // MARK: - Track info

    @ViewBuilder
    private var trackInfo: some View {
        if let metadata = player.currentTrack?.classicalMetadata,
           metadata.isPartOfWork {
            classicalTrackInfo(metadata: metadata)
        } else {
            standardTrackInfo
        }
    }

    private var standardTrackInfo: some View {
        let artistLine = player.currentTrack?.composer
            ?? player.currentTrack?.albumartist
            ?? player.currentTrack?.trackartist
            ?? ""

        return VStack(alignment: .center, spacing: 6) {

            // Title — taps to album detail
            titleButton

            // Artist/composer — taps to artist detail
            if !artistLine.isEmpty {
                artistButton(name: artistLine)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Classical layout: SECTION → WORK → PART → COMPOSER → CONDUCTOR · ENSEMBLE → SOLOISTS.
    /// Each subsidiary line collapses when its data is nil/empty so we never
    /// reserve blank space.
    private func classicalTrackInfo(metadata: ClassicalMetadata) -> some View {
        let composerLine = metadata.composer
            ?? player.currentTrack?.composer
            ?? player.currentTrack?.albumartist
            ?? ""

        let conductorEnsemble: String? = {
            let conductor = metadata.conductor?.trimmingCharacters(in: .whitespacesAndNewlines)
            let ensemble  = metadata.ensemble?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (conductor?.isEmpty == false ? conductor : nil,
                    ensemble?.isEmpty  == false ? ensemble  : nil) {
            case let (c?, e?): return "\(c) · \(e)"
            case let (c?, nil): return c
            case let (nil, e?): return e
            default: return nil
            }
        }()

        let soloistsLine: String? = {
            let soloists = metadata.soloists.filter { !$0.isEmpty }
            return soloists.isEmpty ? nil : soloists.joined(separator: " · ")
        }()

        return VStack(alignment: .center, spacing: 4) {

            // SECTION (opera/oratorio) — smallest, quaternary
            if let section = metadata.section, !section.isEmpty {
                Text(section)
                    .font(.roonBody(11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .kerning(0.8)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.bottom, 2)
            }

            // WORK title — secondary, max 2 lines, truncates with ellipsis
            if let work = metadata.work, !work.isEmpty {
                Text(work)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.bottom, 2)
            }

            // PART (movement label) — main title style; preserves album-tap behaviour.
            titleButton

            // COMPOSER — primary artist line, taps to artist detail.
            if !composerLine.isEmpty {
                artistButton(name: composerLine)
            }

            // CONDUCTOR · ENSEMBLE — caption, tertiary.
            if let line = conductorEnsemble {
                Text(line)
                    .font(.roonBody(12))
                    .foregroundColor(.roonTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // SOLOISTS — caption, tertiary, one line (full list available in info sheet).
            if let line = soloistsLine {
                Text(line)
                    .font(.roonBody(12))
                    .foregroundColor(.roonTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Track-info building blocks

    private var titleButton: some View {
        Button {
            guard let id = player.currentTrack?.albumID,
                  let album = LibraryViewModel.shared.albums.first(where: { $0.id == id })
            else { return }
            albumNavTarget = album
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(player.currentTrack?.title ?? "")
                    .font(.roonTitle(22))
                    .foregroundColor(.roonPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if player.currentTrack?.albumID != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.roonPrimary.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    private func artistButton(name: String) -> some View {
        Button {
            guard let artist = LibraryViewModel.shared.artists.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { return }
            artistNavTarget = artist
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name)
                    .font(.roonBody(16))
                    .foregroundColor(.roonSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.roonSecondary.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scrubber

    private var scrubberSection: some View {
        // Use screen width directly — avoids GeometryReader expansion bug entirely
        let screenW = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 390) - 48 // subtract horizontal padding
        let progress = effectiveDuration > 0
            ? min(isDraggingProgress ? dragProgress : player.currentTime / effectiveDuration, 1)
            : 0
        let fillW = CGFloat(progress) * screenW

        return VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: screenW, height: isDraggingProgress ? 6 : 4)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDraggingProgress)
                // Filled track
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(8, fillW), height: isDraggingProgress ? 6 : 4)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDraggingProgress)
                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .scaleEffect(isDraggingProgress ? 1.5 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isDraggingProgress)
                    .offset(x: max(0, fillW - 8))
            }
            .frame(width: screenW, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isDraggingProgress = true
                        dragProgress = max(0, min(Double(v.location.x / screenW), 1))
                    }
                    .onEnded { _ in
                        player.seek(to: dragProgress * effectiveDuration)
                        isDraggingProgress = false
                    }
            )

            // Timestamps
            HStack {
                Text(formatTime(isDraggingProgress ? dragProgress * effectiveDuration : player.currentTime))
                Spacer()
                Text(formatTime(effectiveDuration))
            }
            .frame(width: screenW)
            .font(.roonMono(12))
            .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: - Progress (work-level, kept for WorkProgressBar)

    private var progressSection: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, geo.size.width * CGFloat(isDraggingProgress ? dragProgress : player.progress)), height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, geo.size.width * CGFloat(isDraggingProgress ? dragProgress : player.progress) - 7))
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let pct = value.location.x / geo.size.width
                        dragProgress = Double(min(max(pct, 0), 1))
                        isDraggingProgress = true
                    }
                    .onEnded { _ in
                        isDraggingProgress = false
                        player.seek(to: dragProgress * effectiveDuration)
                    }
            )
        }
        .frame(height: 44)
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        HStack(spacing: 0) {
            Spacer()
            Button { Haptics.light(); player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == 1 ? "repeat.1" : "repeat")
                    .opacity(player.repeatMode == 0 ? 0.4 : 1.0)
            }
            Spacer()
            Button { Haptics.medium(); player.previousTrack() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28))
            }
            Spacer()
            Button {
                if !player.isLoading { Haptics.medium() }
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
            Spacer()
            Button { Haptics.medium(); player.nextTrack() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28))
            }
            Spacer()
            Button { Haptics.light(); player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .opacity(player.isShuffle ? 1.0 : 0.4)
            }
            Spacer()
        }
        .foregroundColor(.white)
        .font(.system(size: 22))
        .frame(height: 72)
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                Haptics.light()
                withAnimation { showQueuePanel = true }
            } label: {
                Image(systemName: "list.bullet")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button {
                Haptics.light()
                withAnimation { showLyrics.toggle() }
            } label: {
                Image(systemName: showLyrics ? "text.bubble.fill" : "text.bubble")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button {
                if let track = player.currentTrack {
                    Haptics.medium()
                    let wasLiked = likedTracks.isLiked(track)
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
                        likedTracks.toggle(track)
                    }
                    // AUDIT-FIX #1 — mirror love/unlove to Last.fm
                    let lfm = LastFmAuthManager.shared
                    if lfm.isSignedIn {
                        let artist = track.trackartist ?? track.albumartist ?? ""
                        if wasLiked {
                            lfm.unlove(track: track.title ?? "", artist: artist)
                        } else {
                            lfm.love(track: track.title ?? "", artist: artist)
                        }
                    }
                }
            } label: {
                Image(systemName: likedTracks.isLiked(player.currentTrack) ? "heart.fill" : "heart")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button {
                Haptics.light()
                showProfileSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            if player.currentTrack?.classicalMetadata?.isPartOfWork == true {
                Spacer()
                Button {
                    Haptics.light()
                    showClassicalInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Work info")
            }
            Spacer()
            Button {
                Haptics.light()
                showAddToPlaylist = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .foregroundColor(.white)
        .font(.system(size: 20))
        .padding(.horizontal, 8)
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

// MARK: - Work progress bar
//
// Segmented bar: one capsule per movement in the current work group. Past
// movements are filled in accent (dimmed), the current movement is fully
// accent and pulses gently, and future movements are unfilled. Tapping a
// segment hands the entire work to the player at that movement index.

private struct WorkProgressBar: View {
    let group: WorkGroup
    let currentTrackID: Int?

    @State private var isPulsing = false

    private var currentSegmentIndex: Int {
        guard let id = currentTrackID,
              let idx = group.tracks.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(group.tracks.enumerated()), id: \.offset) { idx, track in
                    segment(at: idx, track: track)
                }
            }
            .frame(height: 14)

            HStack {
                Text(group.workTitle)
                    .font(.roonBody(10, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer()
                Text("\(currentSegmentIndex + 1) / \(group.tracks.count)")
                    .font(.roonMono(10))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .onAppear { isPulsing = true }
    }

    private func segment(at index: Int, track: Track) -> some View {
        let isCurrent = index == currentSegmentIndex
        let isPast    = index <  currentSegmentIndex
        let fill: Color = isCurrent
            ? .roonAccent
            : (isPast ? .roonAccent.opacity(0.55) : .white.opacity(0.18))

        // Outer 14-pt tall container is the tap target (matches the
        // surrounding HStack height); inner capsule is a 4-pt visual.
        return ZStack {
            Color.clear
            Capsule()
                .fill(fill)
                .frame(height: 4)
                // Subtle pulse on the current segment only.
                .opacity(isCurrent && isPulsing ? 0.55 : 1.0)
                .animation(
                    isCurrent
                        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("Movement \(index + 1) of \(group.tracks.count): \(track.title)")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .onTapGesture {
            guard !isCurrent else { return }
            Haptics.light()
            PlayerViewModel.shared.playWork(group, startingAt: index)
        }
    }
}

// MARK: - Inline lyrics state

enum InlineLyricsState {
    case loading
    case synced([LyricsLine])
    case plain(String)
    case unavailable

    init(from result: LyricsResult) {
        switch result {
        case .synced(let lines): self = .synced(lines)
        case .plain(let text):   self = .plain(text)
        case .instrumental, .unavailable: self = .unavailable
        }
    }

    var hasContent: Bool {
        switch self {
        case .synced, .plain: return true
        default:              return false
        }
    }
}

// MARK: - Inline lyrics panel

private struct InlineLyricsPanel: View {
    let state: InlineLyricsState
    @ObservedObject var player: PlayerViewModel
    var onExpandTap: () -> Void

    @State private var activeIndex: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch state {
                case .loading:
                    ProgressView().tint(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 120)

                case .synced(let lines):
                    syncedPanel(lines: lines)

                case .plain(let text):
                    plainPanel(text: text)

                case .unavailable:
                    EmptyView()
                }
            }

            Button(action: onExpandTap) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func syncedPanel(lines: [LyricsLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 50)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                        Text(line.text.isEmpty ? "•" : line.text)
                            .font(.roonBody(14, weight: idx == activeIndex ? .semibold : .regular))
                            .foregroundColor(.white.opacity(idx == activeIndex ? 1.0 : 0.4))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                            .animation(.easeOut(duration: 0.18), value: activeIndex)
                    }
                    Color.clear.frame(height: 50)
                }
            }
            .allowsHitTesting(false)
            .onChange(of: activeIndex) { _, idx in
                guard idx < lines.count else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(lines[idx].id, anchor: .center)
                }
            }
            .onChange(of: player.currentTime) { _, time in
                let newIdx = lineIndex(for: time, in: lines)
                if newIdx != activeIndex { activeIndex = newIdx }
            }
            .onAppear {
                let idx = lineIndex(for: player.currentTime, in: lines)
                activeIndex = idx
                if idx < lines.count {
                    proxy.scrollTo(lines[idx].id, anchor: .center)
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func plainPanel(text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(text)
                .font(.roonBody(13))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func lineIndex(for time: TimeInterval, in lines: [LyricsLine]) -> Int {
        let adjusted = time + 0.3
        var result = 0
        for (i, line) in lines.enumerated() {
            if line.time <= adjusted { result = i } else { break }
        }
        return result
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
                Color.black
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
                                    .font(.roonMono(13)).foregroundColor(.roonTertiary)
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

// MARK: - Streaming source pill (expanded Now Playing only)
//
// Shown in place of the playback-profile pill when a Qobuz / Deezer track is
// playing. Carries the source name + a small quality label underneath
// ("24bit · 96kHz" for Qobuz, "FLAC" or "320 kbps" for Deezer).

private struct StreamSourcePill: View {
    let track: StreamTrack

    private var qobuzColor: Color { Color(red: 0,     green: 0.706, blue: 0.847) }
    private var deezerColor: Color { Color(red: 0.937, green: 0.329, blue: 0.4)   }

    private var pillText: String {
        switch track.source {
        case .qobuz:  return "Qobuz"
        case .deezer: return "Deezer"
        case .local:  return ""
        }
    }

    private var pillColor: Color {
        switch track.source {
        case .qobuz:  return qobuzColor
        case .deezer: return deezerColor
        case .local:  return .roonAccent
        }
    }

    private var qualityText: String? {
        if let label = track.qualityLabel, !label.isEmpty { return label }
        switch track.source {
        case .deezer: return "FLAC"
        case .qobuz:  return nil
        case .local:  return nil
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(pillText)
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(pillColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(pillColor.opacity(0.2))
                .clipShape(Capsule())

            if let quality = qualityText {
                Text(quality)
                    .font(.roonBody(10))
                    .foregroundColor(.roonSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Streaming from \(pillText)\(qualityText.map { ", \($0)" } ?? "")")
    }
}
