// ADDED: extracted from PlayerViewModel.swift — private playback, Orpheus path, gapless, crossfade, radio
import AVFoundation
import MediaPlayer
import UIKit

extension PlayerViewModel {

    // MARK: - Private playback

    func playCurrentTrack(autoPlay: Bool = true) {
        guard queue.indices.contains(currentIndex) else { return }

        // Orpheus is the primary engine. AVPlayer path is compatibility fallback only.
        if useOrpheusEngine {
            playCurrentTrackOrpheus(autoPlay: autoPlay)
            return
        }

        let track      = queue[currentIndex]

        // Skip unnecessary item recreation if the current item is already loaded
        // and ready for this exact track. Recreating it tears down the buffer and
        // produces a noticeable gap; a plain resume is all that's needed.
        if let item = playerItem,
           item.status == .readyToPlay,
           player.currentItem === item,
           currentTrack?.id == track.id {
            if autoPlay && !isPlaying { resume() }
            return
        }

        let candidates = LyrionAPI.shared.streamURLs(for: track)
        guard !candidates.isEmpty else {
            isLoading = false
            error     = "Invalid track URL"
            return
        }

        // Detect source format from track metadata
        updateSourceFormat(from: track)
        // Detect actual output format from current audio route
        updateOutputFormat()

        activePlaybackID      = UUID()
        playbackURLCandidates = candidates
        playbackURLIndex      = 0
        lastPlaybackErrorDescription = nil
        ServerLogStore.shared.debug("Starting playback: \(track.title) (source: \(sourceFormat), output: \(outputFormat))")
        beginPlayback(
            track: track,
            url: candidates[0],
            autoPlay: autoPlay,
            playbackID: activePlaybackID
        )
    }

    // MARK: - Orpheus playback path

    func playCurrentTrackOrpheus(autoPlay: Bool = true) {
        guard queue.indices.contains(currentIndex) else { return }

        let track      = queue[currentIndex]
        let candidates = LyrionAPI.shared.streamURLs(for: track)
        guard !candidates.isEmpty else {
            isLoading = false
            error     = "Invalid track URL"
            return
        }

        updateSourceFormat(from: track)
        updateOutputFormat()

        // Set activePlaybackID before any async branch so guards work in all paths.
        activePlaybackID             = UUID()
        let playbackID               = activePlaybackID
        playbackURLCandidates        = candidates
        playbackURLIndex             = 0
        lastPlaybackErrorDescription = nil

        // Reset orpheus diagnostics at the start of each new load.
        orpheusDidStartAudiblePlayback = false
        orpheusDecodedFormat  = ""
        orpheusDurationKnown  = false
        orpheusCanSeek        = false
        orpheusPlaybackMode   = .fileLike
        orpheusStreamKind     = .unknown
        orpheusFallbackReason = nil

        // AirPlay cannot route through AVAudioEngine on all device/OS versions.
        let routeOutputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        if routeOutputs.contains(.airPlay) {
            ServerLogStore.shared.debug("Orpheus: AirPlay output — using AVPlayer fallback")
            // Stop any running engine before this early-return. Without this, the previous
            // track's engine continues feeding the DSP chain while AVPlayer also plays.
            orpheusEngine?.stop()
            orpheusEngine = nil
            isPlaybackRoutedThroughOrpheus = false
            orpheusFallbackReason = "AirPlay output (not supported by AVAudioEngine)"
            beginPlayback(track: track, url: candidates[0], autoPlay: autoPlay, playbackID: playbackID)
            return
        }

        let startTime   = (currentTrack?.id == track.id ? pendingSeekTime : nil) ?? 0
        pendingSeekTime = nil

        currentTrack     = track
        currentStreamURL = candidates[0]
        duration         = track.duration ?? 0
        currentTime      = startTime
        progress         = duration > 0 ? min(1, startTime / duration) : 0
        isLoading        = true
        error            = nil
        isPlaybackRoutedThroughOrpheus = false

        clearPendingSeekWatchdog()
        clearPlaybackStartupWatchdog()
        prefetchTask?.cancel()
        prefetchTask = nil
        lmsAudioQualityTask?.cancel()
        lmsAudioQualityTask = nil

        syncCurrentWorkGroup()

        guard activateAudioSession() else {
            isLoading = false
            isPlaying = false
            isPaused  = false
            return
        }
        if autoPlay, UIApplication.shared.applicationState != .active {
            beginBackgroundPlaybackTask(reason: "orpheus-load-stream")
        }

        // Cancel any in-flight gapless preload — a fresh track is starting.
        pendingOrpheusLoadTask?.cancel()
        pendingOrpheusLoadTask = nil
        pendingOrpheusEngine?.stop()
        pendingOrpheusEngine = nil

        // Resolve the playback profile for this track and apply DSP defaults.
        profileManager.update(for: track)
        applyProfileToDSP()

        orpheusLoadTask?.cancel()
        orpheusLoadTask = nil
        orpheusEngine?.stop()
        let engine = OrpheusPlaybackEngine(manager: audioManager)
        orpheusEngine = engine

        engine.onDurationKnown = { [weak self] dur in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.duration = dur
            self.refreshNowPlayingPlaybackState(force: true)
        }
        engine.onBufferingChanged = { [weak self] buffering in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.isLoading = buffering
        }
        engine.onTimeUpdate = { [weak self] time in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.currentTime = time
            self.progress    = self.duration > 0 ? min(1, time / self.duration) : 0
            self.refreshNowPlayingPlaybackState()
            self.schedulePlaybackStateSave()
            self.checkScrobbleThreshold(time)
            let remaining = self.duration > 0 ? self.duration - time : 0
            let pm = PlaybackProfileManager.shared
            let cfDur = pm.resolvedCrossfadeDuration
            if pm.resolvedCrossfadeEnabled && cfDur > 0
               && remaining > 0 && remaining <= cfDur && !self.isCrossfadingOut {
                self.startCrossfadeOut()
            }
        }
        engine.onPlaybackEnded = { [weak self] in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.trackDidFinish()
        }
        engine.onDecodedFormatKnown = { [weak self] format in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.orpheusDecodedFormat = format
        }
        engine.onError = { [weak self, weak engine] msg in
            guard let self, playbackID == self.activePlaybackID else { return }
            ServerLogStore.shared.warn("Orpheus error: \(msg) — falling back to AVPlayer")
            self.orpheusFallbackReason = "Engine error: \(msg)"
            self.isPlaybackRoutedThroughOrpheus = false
            // Stop the engine before releasing it. Without this the playerNode's
            // scheduled buffers drain as ghost audio while AVPlayer also plays.
            engine?.stop()
            self.orpheusEngine = nil
            self.beginPlayback(track: track, url: candidates[0], autoPlay: autoPlay, playbackID: playbackID)
        }
        engine.onRoutingConfirmed = { [weak self] confirmed in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.isPlaybackRoutedThroughOrpheus = confirmed
            self.orpheusDidStartAudiblePlayback = confirmed
            if confirmed {
                ServerLogStore.shared.info("Orpheus: first audio confirmed through DSP chain")
                // AUDIT-FIX #15 — removed prefetchNextTrackAsset() call here; it
                // races with the call in onNearEnd and causes a double-preload.
                // The sole normal-path trigger is onNearEnd (≤3 s remaining).
                // Schedule gapless preload now that the first track is audibly playing.
                if PlaybackProfileManager.shared.resolvedGaplessEnabled {
                    self.scheduleOrpheusGaplessPreload(for: self.currentIndex)
                }
            }
        }
        engine.onNearEnd = { [weak self] in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.prefetchNextTrackAsset()
            let pm = PlaybackProfileManager.shared
            let cfDur = pm.resolvedCrossfadeDuration
            if pm.resolvedCrossfadeEnabled && cfDur > 0 && !self.isCrossfadingOut {
                self.startCrossfadeOut()
            }
            // Belt-and-suspenders: start gapless preload if not already underway.
            if pm.resolvedGaplessEnabled && self.pendingOrpheusEngine == nil {
                self.scheduleOrpheusGaplessPreload(for: self.currentIndex)
            }
        }

        let headers = LyrionAPI.shared.httpHeaders(
            accept: "audio/flac,audio/mpeg,audio/mp4,audio/aac,audio/wav,audio/*,*/*"
        )

        // Grab the prefetched asset for this track before launching the load task.
        // The prefetch task already started asset.load(.duration) in the background,
        // so reusing this asset skips one (or more) network round-trips inside load().
        var orpheusPreloadedAsset: AVURLAsset? = nil
        if let cached = prefetchedNextAsset, cached.trackID == track.id {
            orpheusPreloadedAsset = cached.asset
            prefetchedNextAsset   = nil
            ServerLogStore.shared.debug("Orpheus: reusing prefetched asset for \(track.title)")
        }

        orpheusLoadTask?.cancel()
        orpheusLoadTask = Task { @MainActor [weak self] in
            guard let self, self.orpheusEngine === engine, playbackID == self.activePlaybackID else { return }
            do {
                try await engine.load(url: candidates[0], headers: headers, startTime: startTime,
                                      preloadedAsset: orpheusPreloadedAsset)
                guard self.orpheusEngine === engine, playbackID == self.activePlaybackID else { return }
                // Mirror engine diagnostic state to published properties.
                self.orpheusDurationKnown  = engine.durationKnown
                self.orpheusCanSeek        = engine.canSeek
                self.orpheusPlaybackMode   = engine.playbackMode
                self.orpheusStreamKind     = engine.streamKind
                if autoPlay {
                    // Do NOT clear isLoading here. engine.play() will set isBuffering=true
                    // via onBufferingChanged, then onStart clears it once audio flows.
                    // Clearing and immediately re-setting causes a visible loading flicker.
                    engine.play()
                    self.isPlaying = true
                    self.isPaused  = false
                    self.endBackgroundPlaybackTask()
                    // Prefetch immediately so lock screen track changes have an asset ready.
                    self.prefetchNextTrackAsset()
                } else {
                    self.isLoading = false
                    self.isPlaying = false
                    self.isPaused  = true
                }
                LibraryViewModel.shared.recordPlayback(track)
                self.updateNowPlayingInfo(track: track)
                self.refreshNowPlayingPlaybackState(force: true)
                self.schedulePlaybackStateSave()
                self.fetchLMSAudioQuality(for: track, playbackID: playbackID)
            } catch {
                guard self.orpheusEngine === engine, playbackID == self.activePlaybackID else { return }
                ServerLogStore.shared.warn("Orpheus load failed: \(error.localizedDescription) — falling back to AVPlayer")
                self.orpheusFallbackReason = "Load failed: \(error.localizedDescription)"
                self.isPlaybackRoutedThroughOrpheus = false
                self.orpheusEngine = nil
                self.beginPlayback(track: track, url: candidates[0], autoPlay: autoPlay, playbackID: playbackID)
            }
        }

        recomputeUpcoming()
        updateNowPlayingInfo(track: track)
        refreshNowPlayingPlaybackState(force: true)
    }

    func updateSourceFormat(from track: Track) {
        if let url = track.url, !url.isEmpty {
            let ext = (url as NSString).pathExtension.uppercased()
            if !ext.isEmpty {
                sourceFormat = ext
                isBitPerfect = false
                return
            }
        }
        sourceFormat = "Unknown"
        isBitPerfect = false
    }

    /// Determine the actual audio output format from the current audio route.
    /// This queries the audio session to detect what the hardware is actually playing.
    func updateOutputFormat() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute

        let outputPortTypes = route.outputs.map(\.portType)
        var categoryName = "Unknown"
        var isLossless = false

        if outputPortTypes.contains(.headphones) {
            categoryName = "Wired headphones"; isLossless = true
        } else if outputPortTypes.contains(.builtInSpeaker) {
            categoryName = "Built-in speaker"; isLossless = true
        } else if outputPortTypes.contains(.airPlay) {
            categoryName = "AirPlay"
        } else if outputPortTypes.contains(.carAudio) {
            categoryName = "CarPlay"
        } else if outputPortTypes.contains(.bluetoothA2DP) || outputPortTypes.contains(.bluetoothLE) {
            categoryName = "Bluetooth"
        } else if !outputPortTypes.isEmpty {
            categoryName = outputPortTypes.first?.rawValue ?? "Unknown"; isLossless = true
        }

        // portName gives the user-visible name (e.g. "AirPods Pro", "James's iPhone").
        let portName = route.outputs.first?.portName ?? ""
        outputDeviceName = portName.isEmpty ? categoryName : portName

        let channelCount = session.outputNumberOfChannels
        let hz = session.sampleRate > 0 ? Int(session.sampleRate) : 48000
        let kHz = hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
        outputFormat = "\(kHz) · \(channelCount)ch"

        _ = isLossless
        isBitPerfect = false

        ServerLogStore.shared.debug("Audio output: \(outputDeviceName) / \(outputFormat)")
    }

    func beginPlayback(
        track: Track,
        url streamURL: URL,
        autoPlay: Bool,
        playbackID: UUID
    ) {
        guard playbackID == activePlaybackID else { return }

        let restoredSeekTime = currentTrack?.id == track.id ? pendingSeekTime : nil

        currentTrack    = track
        currentStreamURL = streamURL
        duration        = track.duration ?? 0
        currentTime     = restoredSeekTime ?? 0
        progress        = duration > 0 ? min(1, currentTime / duration) : 0
        isLoading       = true
        error           = nil
        clearPendingSeekWatchdog()
        clearPlaybackStartupWatchdog()
        prefetchTask?.cancel()
        prefetchTask = nil
        lmsAudioQualityTask?.cancel()
        lmsAudioQualityTask = nil
        crossfadeTask?.cancel()
        crossfadeTask = nil
        isCrossfadingOut = false
        crossfadeVolume = 1
        gaplessPreloadedItem = nil
        radioEarlyFetchTriggered = false
        pendingSeekTime = restoredSeekTime
        if pendingSeekTime != nil { installPendingSeekWatchdog() }

        syncCurrentWorkGroup()

        removeTimeObserver()
        removeItemNotificationObservers()
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil

        guard activateAudioSession() else {
            isLoading = false
            isPlaying = false
            isPaused  = false
            return
        }
        if autoPlay, UIApplication.shared.applicationState != .active {
            beginBackgroundPlaybackTask(reason: "load-stream")
        }
        installPlaybackStartupWatchdog(track: track, autoPlay: autoPlay, playbackID: playbackID)

        // Use prefetched asset if available — its HTTP connection is already
        // established so AVPlayerItem reaches readyToPlay much faster.
        let asset: AVURLAsset
        if let cached = prefetchedNextAsset, cached.trackID == track.id {
            asset = cached.asset
            prefetchedNextAsset = nil
            ServerLogStore.shared.debug("Using prefetched asset for: \(track.title)")
        } else {
            asset = AVURLAsset(url: streamURL, options: [
                "AVURLAssetHTTPHeaderFieldsKey": LyrionAPI.shared.httpHeaders(
                    accept: "audio/flac,audio/mpeg,audio/mp4,audio/aac,audio/wav,audio/*,*/*"
                )
            ])
        }
        let item = AVPlayerItem(asset: asset)
        // Very short initial buffer — LMS is a local server so data arrives
        // almost instantly. 2 seconds is enough to start audio while the rest
        // streams in. This dramatically reduces the perceived latency between
        // tapping Next and hearing sound.
        item.preferredForwardBufferDuration = 2
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        playerItem = item
        ServerLogStore.shared.debug("Player item created: status=\(describeItemStatus(item)), url=\(ServerLogStore.redactedURL(streamURL.absoluteString))")

        // KVO: item readiness & failure.
        statusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self,
                      let expectedItem = item,
                      expectedItem === observedItem,
                      playbackID == self.activePlaybackID,
                      observedItem === self.playerItem else { return }

                ServerLogStore.shared.debug("Player item status changed: \(self.describeItemStatus(observedItem))")
                switch observedItem.status {
                case .readyToPlay:
                    ServerLogStore.shared.info("Playback: Item ready. Track: \(track.title)")
                    self.clearPlaybackStartupWatchdog()
                    self.isLoading = false

                    if let t = self.pendingSeekTime {
                        ServerLogStore.shared.debug("Playback: Applying pending seek to \(String(format: "%.1f", t))s")
                        self.clearPendingSeekWatchdog()
                        self.pendingSeekTime = nil
                        self.player.seek(
                            to: CMTime(seconds: t, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter:  .zero
                        ) { [weak self] _ in
                            guard let self else { return }
                            if autoPlay {
                                self.activateAudioSession()
                                let isInBackground = UIApplication.shared.applicationState != .active
                                self.startPlayer(preferImmediateStart: isInBackground)
                                self.isPlaying = true
                                self.isPaused  = false
                                ServerLogStore.shared.debug("Playback: Started autoPlay (after seek)")
                            }
                        }
                    } else if autoPlay {
                        self.activateAudioSession()
                        let isInBackground = UIApplication.shared.applicationState != .active
                        self.startPlayer(preferImmediateStart: isInBackground)
                        self.isPlaying = true
                        self.isPaused  = false
                        ServerLogStore.shared.debug("Playback: Started autoPlay")
                    }

                    if self.player.timeControlStatus == .playing {
                        self.endBackgroundPlaybackTask()
                    }

                    // Record local play history when the stream actually becomes
                    // playable. This fixes Hyperion's Recently Played section for
                    // direct AVPlayer playback, which LMS does not always log.
                    LibraryViewModel.shared.recordPlayback(track)

                    // Prefetch the next track's asset so skipping forward is instant.
                    self.prefetchNextTrackAsset()

                    // BUG FIX: updateNowPlayingInfo is called at beginPlayback
                    // start, but at that point the asset duration hasn't loaded
                    // yet.  Re-call here once the item is ready so the lock
                    // screen / CarPlay show the correct duration from the outset.
                    self.refreshNowPlayingPlaybackState(force: true)

                case .failed:
                    self.clearPlaybackStartupWatchdog()
                    self.lastPlaybackErrorDescription =
                        observedItem.error?.localizedDescription ?? "Unknown error"
                    ServerLogStore.shared.error("Playback: Item failed. Error: \(self.lastPlaybackErrorDescription ?? "")")
                    self.endBackgroundPlaybackTask()
                    self.retryNextPlaybackURL(
                        track:      track,
                        autoPlay:   autoPlay,
                        playbackID: playbackID
                    )

                default:
                    break
                }
            }
        }

        // KVO: accurate duration from loaded asset.
        durationObservation = item.observe(
            \.duration,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self,
                      let expectedItem = item,
                      expectedItem === observedItem,
                      playbackID == self.activePlaybackID,
                      observedItem === self.playerItem else { return }
                let secs = observedItem.duration.seconds
                if secs.isFinite && secs > 0 {
                    self.duration = secs
                    self.refreshNowPlayingPlaybackState(force: true)
                }
            }
        }

        audioManager.replaceCurrentItem(with: item)
        // LMS is a local network server — disabling stall-avoidance heuristics
        // means AVPlayer starts immediately rather than buffering ahead. On a
        // local Wi-Fi / LAN connection there is effectively no stall risk, and
        // the default value adds hundreds of milliseconds of unnecessary delay.
        player.automaticallyWaitsToMinimizeStalling = false
        // Do NOT set actionAtItemEnd = .pause — keep the default .advance so
        // AVQueuePlayer can step to the pre-inserted gapless item without a gap.
        player.volume = volume * crossfadeVolume

        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] observedPlayer, _ in
            let status = observedPlayer.timeControlStatus
            Task { @MainActor [weak self] in
                // Only process if this observation is for the current active playback.
                guard let self, playbackID == self.activePlaybackID else { return }
                self.handleTimeControlStatus(status, playbackID: playbackID)
            }
        }

        // BUG FIX: The item-end observer was registered for `item` but the
        // `object:` parameter must be the specific AVPlayerItem instance so
        // we don't fire for the wrong item.  This was already correct but we
        // also add a guard that the notification's object matches our current
        // playerItem, defending against a race where a stale item fires its
        // notification after a track change.
        itemEndObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object:  item,
            queue:   .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      playbackID == self.activePlaybackID,
                      (notification.object as? AVPlayerItem) === self.playerItem else { return }
                self.trackDidFinish()
            }
        }

        itemFailureObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object:  item,
            queue:   .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      playbackID == self.activePlaybackID,
                      (notification.object as? AVPlayerItem) === self.playerItem else { return }

                let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.lastPlaybackErrorDescription = failure?.localizedDescription
                    ?? self.playerItem?.error?.localizedDescription
                    ?? "Playback stopped unexpectedly"
                ServerLogStore.shared.warn("Playback failed mid-stream; trying next stream candidate. Error: \(self.lastPlaybackErrorDescription ?? "unknown")")
                self.retryNextPlaybackURL(track: track, autoPlay: autoPlay, playbackID: playbackID)
            }
        }

        itemStalledObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object:  item,
            queue:   .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self,
                      playbackID == self.activePlaybackID,
                      (notification.object as? AVPlayerItem) === self.playerItem else { return }

                self.lastPlaybackErrorDescription = "Playback stalled while buffering"
                self.isLoading = true
                ServerLogStore.shared.warn("Playback stalled; nudging AVPlayer and arming startup watchdog")
                _ = self.activateAudioSession()
                if autoPlay && self.isPlaying {
                    let isInBackground = UIApplication.shared.applicationState != .active
                    if isInBackground && self.backgroundTaskID == .invalid {
                        self.beginBackgroundPlaybackTask(reason: "playback-stalled")
                    }
                    self.startPlayer(preferImmediateStart: isInBackground)
                }
                self.installPlaybackStartupWatchdog(track: track, autoPlay: autoPlay, playbackID: playbackID)
                self.refreshNowPlayingPlaybackState(force: true)
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { [weak self] in
                guard time.isValid, let self, playbackID == self.activePlaybackID else { return }
                let secs = time.seconds
                guard secs.isFinite else { return }
                self.currentTime = max(0, secs)
                self.progress    = self.duration > 0
                    ? min(1, self.currentTime / self.duration)
                    : 0
                self.refreshNowPlayingPlaybackState()
                self.schedulePlaybackStateSave()
                self.checkScrobbleThreshold(self.currentTime)
                let remaining = self.duration > 0 ? self.duration - self.currentTime : 0
                let pm = PlaybackProfileManager.shared
                let cfDur = pm.resolvedCrossfadeDuration
                if !self.isPlaybackRoutedThroughOrpheus
                   && pm.resolvedCrossfadeEnabled && cfDur > 0
                   && remaining > 0 && remaining <= cfDur && !self.isCrossfadingOut {
                    self.startCrossfadeOut()
                }
                if self.isRadioEnabled && !self.radioEarlyFetchTriggered
                   && remaining > 0 && remaining <= 30 {
                    self.radioEarlyFetchTriggered = true
                    self.fetchRadioTracks()
                }
            }
        }

        if autoPlay {
            startPlayer(preferImmediateStart: UIApplication.shared.applicationState != .active)
        } else {
            audioManager.pause()
        }
        isPlaying = autoPlay
        isPaused  = !autoPlay
        recomputeUpcoming()
        updateNowPlayingInfo(track: track)
        refreshNowPlayingPlaybackState(force: true)
        // Persist queue + current index immediately when a track starts so a
        // crash between periodic saves still restores the correct track.
        schedulePlaybackStateSave()

        // Fetch live LMS metadata for the signal-path sheet. Clear first so
        // stale source/status fields are not shown for the next track.
        lmsAudioQuality = nil
        fetchLMSAudioQuality(for: track, playbackID: playbackID)
    }

    /// Fetches the raw LMS fields used by the signal-path model. `songinfo`
    /// is the source of truth for library-file metadata; `status` is retained
    /// as diagnostics because Hyperion's actual playback is AVPlayer direct
    /// streaming, not a normal LMS player output chain.
    ///
    /// LMS tag reference:
    ///   T → samplerate, I → samplesize, o → type, r → bitrate, Q → lossless
    ///   u → url, x → remote, X → album_replay_gain, Y → replay_gain
    func fetchLMSAudioQuality(for track: Track, playbackID: UUID) {
        lmsAudioQualityTask?.cancel()
        lmsAudioQualityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, playbackID == self.activePlaybackID else { return }

            do {
                let tags = "uToIrQXYx"
                let songInfoResult = try await LyrionAPI.shared.request(
                    playerID: "",
                    params: ["songinfo", 0, 100, "track_id:\(track.id)", "tags:\(tags)"]
                )
                guard !Task.isCancelled, playbackID == self.activePlaybackID else { return }

                let songInfo = Self.firstLoopEntry(in: songInfoResult, keys: ["songinfo_loop", "playlist_loop", "titles_loop"]) ?? songInfoResult

                var statusResult: [String: Any] = [:]
                var statusTrack: [String: Any] = [:]
                var statusMatchedCurrentTrack: Bool? = nil
                do {
                    // tags=A adds audio_samplerate / audio_bitdepth / audio_bitrate —
                    // the actual post-transcode wire format for the active LMS player stream.
                    statusResult = try await LyrionAPI.shared.request(params: ["status", "-", 1, "tags:\(tags)A"])
                    statusTrack = Self.firstLoopEntry(in: statusResult, keys: ["playlist_loop"]) ?? [:]
                    if let statusID = Self.intValue(statusTrack["id"] ?? statusTrack["track_id"]) {
                        statusMatchedCurrentTrack = statusID == track.id
                    }
                } catch {
                    ServerLogStore.shared.debug("LMS status diagnostics unavailable for signal path: \(error.localizedDescription)")
                }

                // Stream format from tags=A — top-level status fields, not playlist_loop
                let streamSampleRate = Self.intValue(statusResult["audio_samplerate"]).flatMap { $0 > 0 ? $0 : nil }
                let streamBitDepth   = Self.intValue(statusResult["audio_bitdepth"]).flatMap { $0 > 0 ? $0 : nil }
                let streamBitRate    = Self.stringValue(statusResult["audio_bitrate"])?.trimmingCharacters(in: .whitespaces)

                let statusCanFill = statusMatchedCurrentTrack == true
                let type = Self.firstString([songInfo["type"], statusCanFill ? statusTrack["type"] : nil, track.audioType])?.lowercased() ?? ""
                #if DEBUG
                print("[AudioQuality] type='\(type)' samplerate=\(Self.firstInt([songInfo["samplerate"], statusCanFill ? statusTrack["samplerate"] : nil, track.sampleRate]) ?? 0) statusMatched=\(String(describing: statusMatchedCurrentTrack))")
                #endif
                let sampleRate = Self.firstInt([songInfo["samplerate"], statusCanFill ? statusTrack["samplerate"] : nil, track.sampleRate]) ?? 0
                let sampleSize = Self.firstInt([songInfo["samplesize"], statusCanFill ? statusTrack["samplesize"] : nil, track.sampleSize]) ?? 0
                let bitrate = Self.firstString([songInfo["bitrate"], statusCanFill ? statusTrack["bitrate"] : nil, track.bitrate])
                let lossless = Self.firstBool([songInfo["lossless"], statusCanFill ? statusTrack["lossless"] : nil, track.lossless])
                let url = Self.firstString([songInfo["url"], statusCanFill ? statusTrack["url"] : nil, track.url])
                let remote = Self.firstBool([songInfo["remote"], statusCanFill ? statusTrack["remote"] : nil, track.isRemote])
                let replayGain = Self.firstDouble([songInfo["replay_gain"], statusCanFill ? statusTrack["replay_gain"] : nil, track.replayGain])
                let albumReplayGain = Self.firstDouble([songInfo["album_replay_gain"], statusCanFill ? statusTrack["album_replay_gain"] : nil, track.albumReplayGain])
                let playerName = Self.stringValue(statusResult["player_name"] ?? statusResult["name"])
                let playerMode = Self.stringValue(statusResult["mode"])
                let lmsVolume = Self.intValue((statusResult["mixer volume"] ?? statusResult["volume"]))

                let expectedFields = ["type", "samplerate", "samplesize", "bitrate", "lossless", "url", "replay_gain", "album_replay_gain"]
                var fieldsUsed: [String] = []
                if !type.isEmpty { fieldsUsed.append("type") }
                if sampleRate > 0 { fieldsUsed.append("samplerate") }
                if sampleSize > 0 { fieldsUsed.append("samplesize") }
                if bitrate?.isEmpty == false { fieldsUsed.append("bitrate") }
                if lossless != nil { fieldsUsed.append("lossless") }
                if url?.isEmpty == false { fieldsUsed.append("url") }
                if replayGain != nil { fieldsUsed.append("replay_gain") }
                if albumReplayGain != nil { fieldsUsed.append("album_replay_gain") }
                let missing = expectedFields.filter { !fieldsUsed.contains($0) }

                var rawStatusFields = Self.rawFieldMap(statusResult)
                for (key, value) in Self.rawFieldMap(statusTrack) {
                    rawStatusFields["playlist_loop.\(key)"] = value
                }

                self.lmsAudioQuality = LMSAudioQuality(
                    sampleRate: sampleRate,
                    sampleSize: sampleSize,
                    type: type,
                    bitrate: bitrate,
                    lossless: lossless,
                    url: url,
                    remote: remote,
                    replayGain: replayGain,
                    albumReplayGain: albumReplayGain,
                    playerName: playerName,
                    playerMode: playerMode,
                    lmsVolume: lmsVolume,
                    streamSampleRate: streamSampleRate,
                    streamBitDepth: streamBitDepth,
                    streamBitRate: streamBitRate?.isEmpty == false ? streamBitRate : nil,
                    outputDeviceName: self.outputDeviceName.isEmpty ? nil : self.outputDeviceName,
                    rawTrackFields: Self.rawFieldMap(songInfo),
                    rawStatusFields: rawStatusFields,
                    fieldsUsed: fieldsUsed,
                    missingFields: missing,
                    statusMatchedCurrentTrack: statusMatchedCurrentTrack
                )

                // Re-apply ReplayGain now that authoritative LMS tags are available
                // (the per-track push in applyProfileToDSP ran before songinfo).
                self.pushReplayGainToDSP()

                ServerLogStore.shared.debug(
                    "Signal path LMS fields used: \(fieldsUsed.joined(separator: ", ")); missing: \(missing.joined(separator: ", "))"
                )
            } catch is CancellationError {
                // Track changed; no UI update needed.
            } catch {
                ServerLogStore.shared.debug("LMS signal-path metadata fetch skipped: \(error.localizedDescription)")
                self.lmsAudioQuality = LMSAudioQuality(
                    sampleRate: track.sampleRate ?? 0,
                    sampleSize: track.sampleSize ?? 0,
                    type: track.audioType ?? "",
                    bitrate: track.bitrate,
                    lossless: track.lossless,
                    url: track.url,
                    remote: track.isRemote,
                    replayGain: track.replayGain,
                    albumReplayGain: track.albumReplayGain,
                    playerName: nil,
                    playerMode: nil,
                    lmsVolume: nil,
                    streamSampleRate: nil,
                    streamBitDepth: nil,
                    streamBitRate: nil,
                    outputDeviceName: self.outputDeviceName.isEmpty ? nil : self.outputDeviceName,
                    rawTrackFields: [:],
                    rawStatusFields: [:],
                    fieldsUsed: [],
                    missingFields: ["songinfo", "status"],
                    statusMatchedCurrentTrack: nil
                )
            }
        }
    }

    private nonisolated static func firstLoopEntry(in result: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let arr = result[key] as? [[String: Any]], let first = arr.first { return first }
        }
        return nil
    }

    private nonisolated static func firstString(_ values: [Any?]) -> String? {
        for value in values {
            if let string = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private nonisolated static func firstInt(_ values: [Any?]) -> Int? {
        for value in values {
            if let int = intValue(value), int > 0 { return int }
        }
        return nil
    }

    private nonisolated static func firstDouble(_ values: [Any?]) -> Double? {
        for value in values {
            if let double = doubleValue(value) { return double }
        }
        return nil
    }

    private nonisolated static func firstBool(_ values: [Any?]) -> Bool? {
        for value in values {
            if let bool = boolValue(value) { return bool }
        }
        return nil
    }

    private nonisolated static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(t) { return i }
            if let d = Double(t) { return Int(d) }
            return nil
        default: return nil
        }
    }

    private nonisolated static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private nonisolated static func boolValue(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let i as Int: return i != 0
        case let d as Double: return d != 0
        case let n as NSNumber: return n.boolValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "lossless"].contains(t) { return true }
            if ["0", "false", "no", "lossy"].contains(t) { return false }
            return nil
        default: return nil
        }
    }

    private nonisolated static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return String(b)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private nonisolated static func rawFieldMap(_ dict: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in dict {
            let lower = key.lowercased()
            if lower.contains("url"), let s = stringValue(value) {
                out[key] = ServerLogStore.redactedURL(s)
            } else if let s = stringValue(value) {
                out[key] = s
            }
        }
        return out
    }

    func retryNextPlaybackURL(track: Track, autoPlay: Bool, playbackID: UUID) {
        guard playbackID == activePlaybackID else { return }

        let nextIndex = playbackURLIndex + 1
        guard playbackURLCandidates.indices.contains(nextIndex) else {
            clearPlaybackStartupWatchdog()
            let message = lastPlaybackErrorDescription ?? "Playback failed"
            error     = "Playback failed after trying all stream formats. Last error: \(message)"
            isLoading = false
            isPlaying = false
            isPaused  = false
            endBackgroundPlaybackTask()
            refreshNowPlayingPlaybackState(force: true)
            return
        }

        playbackURLIndex = nextIndex
        beginPlayback(
            track:      track,
            url:        playbackURLCandidates[nextIndex],
            autoPlay:   autoPlay,
            playbackID: playbackID
        )
    }


    func installPlaybackStartupWatchdog(track: Track, autoPlay: Bool, playbackID: UUID) {
        playbackStartupWatchdogTask?.cancel()
        playbackStartupWatchdogTask = Task { @MainActor [weak self] in
            // AVPlayerItem.status can remain `.unknown` indefinitely on a
            // half-open LMS/proxy connection. Without this watchdog the UI sits
            // in a permanent loading state and background playback never starts.
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, playbackID == self.activePlaybackID else { return }
            guard self.isLoading else { return }

            let itemReady = self.playerItem?.status == .readyToPlay
            let playerAudible = self.player.timeControlStatus == .playing || self.player.rate > 0
            guard !itemReady || !playerAudible else { return }

            self.lastPlaybackErrorDescription = "Timed out waiting for stream to start"
            ServerLogStore.shared.warn("Playback startup timed out; trying next stream candidate")
            self.retryNextPlaybackURL(track: track, autoPlay: autoPlay, playbackID: playbackID)
        }
    }

    func clearPlaybackStartupWatchdog() {
        playbackStartupWatchdogTask?.cancel()
        playbackStartupWatchdogTask = nil
    }

    func startPlayer(preferImmediateStart: Bool = false) {
        // Always use playImmediately — on a local LMS server there is no
        // network buffering delay to protect against, and this eliminates the
        // "waiting to play at specified rate" pause that adds ~300–500 ms.
        player.playImmediately(atRate: 1.0)
    }

    /// Prefetch the next track's AVURLAsset so its HTTP headers are already
    /// resolved when the user skips. Also pre-inserts an AVPlayerItem into the
    /// AVQueuePlayer so it can advance gaplessly when the current item ends.
    func prefetchNextTrackAsset() {
        let nextIndex = currentIndex + 1
        guard queue.indices.contains(nextIndex) else {
            prefetchedNextAsset = nil
            return
        }
        let nextTrack = queue[nextIndex]
        // Skip if we already have this track prefetched.
        if let cached = prefetchedNextAsset, cached.trackID == nextTrack.id { return }

        let candidates = LyrionAPI.shared.streamURLs(for: nextTrack)
        guard let url = candidates.first else { return }

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": LyrionAPI.shared.httpHeaders(
                accept: "audio/flac,audio/mpeg,audio/mp4,audio/aac,audio/wav,audio/*,*/*"
            )
        ])
        // Warm the HTTP connection without downloading audio data.
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .userInitiated) {
            _ = try? await asset.load(.duration)
        }
        prefetchedNextAsset = (trackID: nextTrack.id, asset: asset)

        // Pre-insert a player item for gapless advance (AVPlayer path only).
        // Only when gapless is enabled for the current profile — if it's off, we still
        // prefetch the asset (fast skip) but don't pre-insert into AVQueuePlayer.
        if !isPlaybackRoutedThroughOrpheus && profileManager.resolvedGaplessEnabled {
            let gaplessItem = AVPlayerItem(asset: asset)
            gaplessItem.preferredForwardBufferDuration = 2
            gaplessItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            gaplessPreloadedItem = (trackID: nextTrack.id, item: gaplessItem, url: url)
            audioManager.preloadNextItem(gaplessItem)
            ServerLogStore.shared.debug("Gapless item queued for: \(nextTrack.title)")
        } else {
            ServerLogStore.shared.debug("Prefetched next track asset: \(nextTrack.title)")
        }
    }

    func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus, playbackID: UUID) {
        guard playbackID == activePlaybackID else {
            // This is a stale observation from a previous playback session.
            // Ignore it to prevent race conditions.
            return
        }

        ServerLogStore.shared.debug("AVPlayer timeControlStatus=\(describeTimeControlStatus(status)), rate=\(String(format: "%.2f", player.rate)), item=\(describeItemStatus(playerItem))")

        switch status {
        case .playing:
            // Playback has started. The audio session is now active and the system
            // audio background mode is managing process lifetime. We can release the
            // explicit background task since the audio daemon will keep us alive.
            if isPlaying {
                ServerLogStore.shared.info("Playback started, audio background mode active")
                isHandlingBackgroundTransition = false
                endBackgroundPlaybackTask()
                refreshNowPlayingPlaybackState(force: true)
            }

        case .waitingToPlayAtSpecifiedRate:
            // Player is buffering or preparing to start. This can take time on
            // slow networks. Keep the explicit background task alive to prevent
            // iOS from suspending the process before playback begins.
            if isPlaying {
                ServerLogStore.shared.debug("Buffering / preparing playback")
                activateAudioSession()
                let isInBackground = UIApplication.shared.applicationState != .active
                if isInBackground && backgroundTaskID == .invalid {
                    beginBackgroundPlaybackTask(reason: "buffering")
                }
                refreshNowPlayingPlaybackState(force: true)
                // 3 s watchdog: if still stuck waiting with a ready item, nudge the player.
                playbackStartupWatchdogTask?.cancel()
                playbackStartupWatchdogTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self, !Task.isCancelled, playbackID == self.activePlaybackID else { return }
                    guard self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                    guard self.playerItem?.status == .readyToPlay else { return }
                    ServerLogStore.shared.warn("Playback stuck waiting 3 s — nudging player")
                    _ = self.activateAudioSession()
                    self.startPlayer(preferImmediateStart: true)
                    self.playbackStartupWatchdogTask = nil
                }
            }

        case .paused:
            // Player is paused. This can happen because we called pause(), or
            // because of an interruption/buffer starvation/error. If the player
            // paused unexpectedly, sync our state to match reality.
            ServerLogStore.shared.debug("Playback paused")
            if isPlaying {
                // AVPlayer briefly drops to .paused during the background hand-off
                // (between willResignActive and the audio daemon taking over the
                // session). Treat any pause report during that hand-off as
                // transient — not as a user pause — so we do not deactivate or
                // mark playback stopped while iOS is moving audio to background.
                let isInBackground = UIApplication.shared.applicationState != .active
                if isInBackground || isHandlingBackgroundTransition {
                    ServerLogStore.shared.debug("AVPlayer paused during background transition — preserving playing state")
                    refreshNowPlayingPlaybackState(force: true)
                    return
                }
                // Unexpected pause with no active background transition
                // (buffer starvation, interruption, etc.). Sync state.
                // BUG FIX: if the item has .failed status, the item-failure KVO
                // handler will drive retryNextPlaybackURL — do not also mark isPaused
                // here or the UI gets stuck showing "paused" instead of retrying.
                if playerItem?.status == .failed {
                    ServerLogStore.shared.debug("AVPlayer paused due to item failure — retry handled by KVO observer")
                    return
                }
                ServerLogStore.shared.warn("AVPlayer paused unexpectedly, syncing state")
                endBackgroundPlaybackTask()
                isPlaying = false
                isPaused = true
                refreshNowPlayingPlaybackState(force: true)
            } else {
                endBackgroundPlaybackTask()
            }

        @unknown default:
            ServerLogStore.shared.debug("Unknown timeControlStatus")
        }
    }

    /// Resolves the current work group from the WORK tag on the playing track's
    /// classical metadata. Replaces the prior queue-heuristic implementation:
    /// the canonical source is now LMS's WORK/work_id tags via the resolver.
    ///
    /// Behavior:
    ///   • No track, or no work tag → currentWorkGroup = nil.
    ///   • Same workID as currently set → no-op (avoid churn / redundant fetch).
    ///   • New workID → clear immediately, then fetch tracks in the work group
    ///     via LyrionAPI.fetchTracksForWork (cached) and assign when ready.
    ///   • Stale guard: if the track changes during the async fetch, the
    ///     result is discarded.
    func syncCurrentWorkGroup() {
        guard let track = currentTrack,
              let metadata = track.classicalMetadata,
              metadata.isPartOfWork,
              let workID = metadata.workID,
              workID > 0 else {
            currentWorkGroup = nil
            return
        }

        // Already showing this work — leave it alone so a same-work track
        // change doesn't blink the UI between fetch resolutions.
        if currentWorkGroup?.id == workID { return }

        // Different work (or none yet). Clear before the async fetch resolves.
        currentWorkGroup = nil

        let trackIDAtStart = track.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await LyrionAPI.shared.fetchTracksForWork(workID: workID)
            // Stale: the user moved on before the fetch came back.
            guard let current = self.currentTrack,
                  current.id == trackIDAtStart,
                  current.classicalMetadata?.workID == workID,
                  !tracks.isEmpty else { return }

            self.currentWorkGroup = WorkGroup(
                id:        workID,
                workTitle: metadata.work ?? current.work ?? "Work",
                composer:  metadata.composer ?? current.composer,
                tracks:    tracks,
                coverid:   tracks.first?.coverid ?? current.coverid
            )
        }
    }

    func trackDidFinish() {
        switch repeatMode {
        case 1:
            currentTime     = 0
            progress        = 0
            pendingSeekTime = nil
            if isPlaybackRoutedThroughOrpheus {
                // Reload from the start for repeat-one; simpler than seeking a finished asset.
                playCurrentTrackOrpheus(autoPlay: true)
            } else {
                let seekGeneration = activePlaybackID
                player.seek(
                    to: .zero,
                    toleranceBefore: .zero,
                    toleranceAfter:  .zero
                ) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self, finished, seekGeneration == self.activePlaybackID else { return }
                        self.activateAudioSession()
                        self.startPlayer(preferImmediateStart: UIApplication.shared.applicationState != .active)
                        self.isPlaying = true
                        self.isPaused  = false
                        self.refreshNowPlayingPlaybackState(force: true)
                    }
                }
            }
        default:
            if SleepTimerManager.shared.consumeEndOfTrackTrigger() {
                isPlaying = false
                isPaused  = false
                endBackgroundPlaybackTask()
                refreshNowPlayingPlaybackState(force: true)
                deactivateAudioSession()
                return
            }
            if currentIndex < queue.count - 1 || repeatMode == 2 {
                let nextIdx = (repeatMode == 2 && currentIndex >= queue.count - 1) ? 0 : currentIndex + 1

                // Orpheus gapless path — pending engine is already feeding the node.
                if isPlaybackRoutedThroughOrpheus,
                   shouldUseGaplessForNextTrack(from: currentIndex),
                   let pending = pendingOrpheusEngine,
                   queue.indices.contains(nextIdx) {
                    performOrpheusGaplessHandoff(pending: pending, nextIndex: nextIdx)
                    return
                }

                // AVPlayer gapless path — pre-inserted item plays with no gap.
                if !isPlaybackRoutedThroughOrpheus,
                   shouldUseGaplessForNextTrack(from: currentIndex),
                   let g = gaplessPreloadedItem,
                   queue.indices.contains(nextIdx),
                   g.trackID == queue[nextIdx].id {
                    if g.item.status == .failed {
                        ServerLogStore.shared.warn("Gapless: preloaded item failed — falling back to nextTrack()")
                        gaplessPreloadedItem = nil
                        audioManager.removePreloadedItems()
                        nextTrack()
                    } else {
                        performGaplessAdvance(nextIndex: nextIdx)
                    }
                    return
                }

                // No gapless — respect inter-track gap if configured.
                let gap = profileManager.resolvedInterTrackGap.rawValue
                if gap > 0 {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self.nextTrack()
                    }
                } else {
                    nextTrack()
                }
            } else if isRadioEnabled {
                // Queue exhausted — radio refresh was already triggered early;
                // if it hasn't arrived yet, fetch now.
                if !radioEarlyFetchTriggered { fetchRadioTracks() }
            } else {
                isPlaying = false
                isPaused  = false
                endBackgroundPlaybackTask()
                refreshNowPlayingPlaybackState(force: true)
                deactivateAudioSession()
            }
        }
    }

    // MARK: - Gapless advance

    /// Updates PlayerViewModel state when AVQueuePlayer automatically steps to
    /// the pre-inserted gapless item. No `replaceCurrentItem` call — the player
    /// is already playing the new item. We just reinstall all observers.
    func performGaplessAdvance(nextIndex: Int) {
        guard queue.indices.contains(nextIndex), let gItem = gaplessPreloadedItem else {
            nextTrack(); return
        }

        let track = queue[nextIndex]
        gaplessPreloadedItem = nil
        radioEarlyFetchTriggered = false

        crossfadeTask?.cancel()
        isCrossfadingOut = false

        removeTimeObserver()
        removeItemNotificationObservers()
        statusObservation?.invalidate();      statusObservation      = nil
        durationObservation?.invalidate();    durationObservation    = nil
        timeControlObservation?.invalidate(); timeControlObservation = nil

        currentIndex     = nextIndex
        currentTrack     = track
        duration         = track.duration ?? 0
        currentTime      = 0
        progress         = 0
        isLoading        = false
        isPlaying        = true
        isPaused         = false
        error            = nil
        currentStreamURL = gItem.url

        playerItem           = gItem.item
        let item             = gItem.item
        let playbackID       = UUID()
        activePlaybackID     = playbackID

        lmsAudioQualityTask?.cancel()
        lmsAudioQuality = nil

        syncCurrentWorkGroup()
        updateNowPlayingInfo(track: track)
        refreshNowPlayingPlaybackState(force: true)
        LibraryViewModel.shared.recordPlayback(track)

        // Reinstall time observer with the new playbackID so the progress bar
        // keeps updating and crossfade/radio triggers fire for the new track.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { [weak self] in
                guard time.isValid, let self, playbackID == self.activePlaybackID else { return }
                let secs = time.seconds
                guard secs.isFinite else { return }
                self.currentTime = max(0, secs)
                self.progress    = self.duration > 0 ? min(1, self.currentTime / self.duration) : 0
                self.refreshNowPlayingPlaybackState()
                self.schedulePlaybackStateSave()
                let remaining = self.duration > 0 ? self.duration - self.currentTime : 0
                let pm = PlaybackProfileManager.shared
                let cfDur = pm.resolvedCrossfadeDuration
                if pm.resolvedCrossfadeEnabled && cfDur > 0
                   && remaining > 0 && remaining <= cfDur && !self.isCrossfadingOut {
                    self.startCrossfadeOut()
                }
                if self.isRadioEnabled && !self.radioEarlyFetchTriggered && remaining > 0 && remaining <= 30 {
                    self.radioEarlyFetchTriggered = true
                    self.fetchRadioTracks()
                }
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] obs, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let ei = item, ei === obs,
                      playbackID == self.activePlaybackID, obs === self.playerItem else { return }
                if obs.status == .readyToPlay {
                    self.isLoading = false
                    self.prefetchNextTrackAsset()
                    self.refreshNowPlayingPlaybackState(force: true)
                }
            }
        }

        durationObservation = item.observe(\.duration, options: [.new]) { [weak self, weak item] obs, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let ei = item, ei === obs,
                      playbackID == self.activePlaybackID, obs === self.playerItem else { return }
                let secs = obs.duration.seconds
                if secs.isFinite && secs > 0 {
                    self.duration = secs
                    self.refreshNowPlayingPlaybackState(force: true)
                }
            }
        }

        itemEndObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, playbackID == self.activePlaybackID,
                      (notification.object as? AVPlayerItem) === self.playerItem else { return }
                self.trackDidFinish()
            }
        }

        itemFailureObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, playbackID == self.activePlaybackID,
                      (notification.object as? AVPlayerItem) === self.playerItem else { return }
                let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.lastPlaybackErrorDescription = failure?.localizedDescription ?? "Playback stopped unexpectedly"
                ServerLogStore.shared.warn("Gapless: item failed — \(self.lastPlaybackErrorDescription ?? "unknown")")
                self.playCurrentTrack(autoPlay: true)
            }
        }

        itemStalledObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, playbackID == self.activePlaybackID,
                      (notification.object as? AVPlayerItem) === self.playerItem else { return }
                self.isLoading = true
                ServerLogStore.shared.warn("Gapless: playback stalled")
                _ = self.activateAudioSession()
                if self.isPlaying {
                    self.startPlayer(preferImmediateStart: UIApplication.shared.applicationState != .active)
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] obs, _ in
            let status = obs.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, playbackID == self.activePlaybackID else { return }
                self.handleTimeControlStatus(status, playbackID: playbackID)
            }
        }

        startCrossfadeIn()
        prefetchNextTrackAsset()
        fetchLMSAudioQuality(for: track, playbackID: playbackID)
        schedulePlaybackStateSave()

        ServerLogStore.shared.info("Gapless advance → \(track.title)")
    }

    // MARK: - Crossfade (AVPlayer path only)

    /// Ramp `crossfadeVolume` from its current value down to 0 over `crossfadeDuration`.
    /// Uses an equal-power (cosine) curve so perceived loudness stays constant
    /// throughout the crossfade and avoids the volume dip that a linear ramp produces.
    func startCrossfadeOut() {
        let pm = PlaybackProfileManager.shared
        let cfDur = pm.resolvedCrossfadeDuration
        guard pm.resolvedCrossfadeEnabled, cfDur > 0 else { return }
        // Gapless pre-inserts the next AVPlayerItem and expects the player to
        // advance seamlessly; crossfade simultaneously ramps volume to 0 which
        // defeats that expectation and produces a silent gap instead of a blend.
        guard !pm.resolvedGaplessEnabled else { return }
        if let engine = orpheusEngine, !engine.crossfadeEligible { return }
        isCrossfadingOut = true
        crossfadeTask?.cancel()

        let shape = pm.resolvedCrossfadeShape
        if let engine = orpheusEngine {
            crossfadeTask = engine.rampVolume(to: 0, over: cfDur, shape: shape)
            return
        }

        let steps    = max(1, Int(cfDur / 0.016))
        let startVol = crossfadeVolume
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for i in 0..<steps {
                guard !Task.isCancelled else { return }
                let t   = Float(i + 1) / Float(steps)
                let vol = shape.gain(t: t, fadingOut: true) * startVol
                self.crossfadeVolume = max(0, vol)
                self.player.volume   = max(0, min(1, self.volume)) * self.crossfadeVolume
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.crossfadeVolume = 0
            self.player.volume   = 0
        }
    }

    func startCrossfadeIn() {
        let pm = PlaybackProfileManager.shared
        let cfDur = pm.resolvedCrossfadeDuration
        crossfadeTask?.cancel()
        isCrossfadingOut = false
        guard pm.resolvedCrossfadeEnabled, cfDur > 0 else {
            crossfadeVolume       = 1
            player.volume         = max(0, min(1, volume))
            orpheusEngine?.volume = 1
            return
        }

        let shape = pm.resolvedCrossfadeShape
        if let engine = orpheusEngine {
            engine.volume = 0
            crossfadeTask = engine.rampVolume(to: 1, over: cfDur, shape: shape)
            return
        }

        crossfadeVolume = 0
        player.volume   = 0
        let steps = max(1, Int(cfDur / 0.016))
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for i in 0..<steps {
                guard !Task.isCancelled else { return }
                let t   = Float(i + 1) / Float(steps)
                let vol = shape.gain(t: t, fadingOut: false)
                self.crossfadeVolume = min(1, vol)
                self.player.volume   = max(0, min(1, self.volume)) * self.crossfadeVolume
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.crossfadeVolume = 1
            self.player.volume   = max(0, min(1, self.volume))
        }
    }

    // MARK: - Radio queue refresh

    func fetchRadioTracks() {
        radioRefreshTask?.cancel()
        let seedTrack = currentTrack
        radioRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await Self.radioTracks(seedTrack: seedTrack)
            guard !Task.isCancelled, !tracks.isEmpty else { return }
            let deduped = tracks.filter { t in !self.queue.contains { $0.id == t.id } }
            guard !deduped.isEmpty else { return }
            self.addTracksToQueue(deduped)
            self.nextTrack()
        }
    }

    static func radioTracks(seedTrack: Track?) async -> [Track] {
        // Radio is the non-classical suggestion engine. Classical tracks never
        // enter it — whether classical mode is off (hidden everywhere) or on
        // (classical discovery lives only in the Classical tab). The two engines
        // stay separate.
        func nonClassical(_ tracks: [Track]) -> [Track] {
            tracks.filter { !$0.looksClassical }
        }

        // Try to get tracks for the seed track's genre; fall back to random songs.
        if let genreStr = seedTrack?.genres,
           let genreName = genreStr.split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
           !genreName.isEmpty,
           let genre = LibraryViewModel.shared.genres.first(where: { $0.name == genreName }) {
            let tracks = nonClassical((try? await LyrionAPI.shared.getTracksForGenre(genreID: genre.id, count: 30)) ?? [])
            if !tracks.isEmpty { return Array(tracks.shuffled().prefix(10)) }
        }
        // Fallback: random songs from library
        let songs = nonClassical(LibraryViewModel.shared.songs)
        if !songs.isEmpty { return Array(songs.shuffled().prefix(10)) }
        return []
    }

    // MARK: - Work-boundary gapless (Stage 6)

    /// Whether the transition from `currentIdx` to the next track should be
    /// gapless. Under the classical profile, gapless is restricted to movements
    /// of the SAME work (equal, non-nil workID); across different works (or when
    /// either workID is unknown) the track plays to its natural end instead.
    /// Other profiles keep the existing behaviour (resolvedGaplessEnabled).
    func shouldUseGaplessForNextTrack(from currentIdx: Int) -> Bool {
        guard profileManager.resolvedGaplessEnabled else { return false }
        guard profileManager.activeProfile == .classical else { return true }

        let nextIdx = currentIdx + 1
        guard queue.indices.contains(currentIdx), queue.indices.contains(nextIdx) else {
            // Wrap-around (repeat-all) or out of range → treat as a work boundary.
            return false
        }
        guard let a = queue[currentIdx].classicalMetadata?.workID,
              let b = queue[nextIdx].classicalMetadata?.workID,
              a == b else {
            return false   // different work, or metadata not resolved → natural end
        }
        return true
    }

    // MARK: - Profile activation (Stage 6)

    /// Force the classical profile while the Classical tab is open. Saves the
    /// current profile so it can be restored on leaving.
    func activateClassicalProfile() {
        guard profileManager.forcedProfile != .classical else { return }
        previousProfileID = profileManager.activeProfile.rawValue
        profileManager.setForcedProfile(.classical, currentTrack: currentTrack)
        applyProfileToDSP()
        showProfileToast("Classical mode")
    }

    /// Clear the forced classical profile; per-track auto-detection resumes.
    func restorePreviousProfile() {
        guard profileManager.forcedProfile != nil else { return }
        profileManager.setForcedProfile(nil, currentTrack: currentTrack)
        applyProfileToDSP()
        previousProfileID = nil
        showProfileToast("Restored \(profileManager.activeProfile.displayName)")
    }

    private func showProfileToast(_ message: String) {
        profileToast = message
        profileToastTask?.cancel()
        profileToastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.profileToast = nil
        }
    }

    // MARK: - Profile DSP integration

    /// Apply the current profile's crossfeed and preset to OrpheusDSPEngine.
    /// Called at the start of each track and during gapless handoff.
    func applyProfileToDSP() {
        let pm  = profileManager
        let dsp = OrpheusDSPEngine.shared

        // crossfeedBypassed = user's permanent setting (unchanged).
        // profileDrivenCrossfeedBypassed = profile's recommendation.
        let wantCrossfeed = pm.resolvedCrossfeedEnabled
        dsp.profileDrivenCrossfeedBypassed = !wantCrossfeed

        if wantCrossfeed {
            dsp.applyCrossfeedPreset(pm.resolvedCrossfeedPreset)
        }

        pushReplayGainToDSP()
    }

    /// Push ReplayGain profile settings and the current track's RG tag values to
    /// the DSP engine. Prefers the authoritative LMS songinfo tags
    /// (lmsAudioQuality) and falls back to the track model's own tags.
    func pushReplayGainToDSP() {
        let s   = profileManager.resolvedSettings
        let dsp = OrpheusDSPEngine.shared
        dsp.replayGainEnabled  = s.replayGainEnabled
        dsp.replayGainMode     = s.replayGainMode
        dsp.replayGainPreampDB = Float(s.replayGainPreamp)
        let trackGain = lmsAudioQuality?.replayGain ?? currentTrack?.replayGain
        let albumGain = lmsAudioQuality?.albumReplayGain ?? currentTrack?.albumReplayGain
        dsp.setReplayGainValues(trackGainDB: trackGain, albumGainDB: albumGain)
    }

    // MARK: - Orpheus gapless preload

    /// Create and start loading a second OrpheusPlaybackEngine for the next track.
    /// When ready, `playGapless()` begins feeding the next track's PCM buffers into
    /// the already-running player node so there is no silence between tracks.
    func scheduleOrpheusGaplessPreload(for currentIdx: Int) {
        let nextIdx = currentIdx + 1
        guard queue.indices.contains(nextIdx) else { return }
        // Work-boundary gapless: under the classical profile, only preload when
        // the next track is part of the same work. Across works, let the current
        // track end naturally (no preload, no gapless handoff).
        guard shouldUseGaplessForNextTrack(from: currentIdx) else { return }
        // Don't double-preload.
        guard pendingOrpheusEngine == nil else { return }

        let nextTrack = queue[nextIdx]
        let candidates = LyrionAPI.shared.streamURLs(for: nextTrack)
        guard let url = candidates.first else { return }

        let headers = LyrionAPI.shared.httpHeaders(
            accept: "audio/flac,audio/mpeg,audio/mp4,audio/aac,audio/wav,audio/*,*/*"
        )

        let engine = OrpheusPlaybackEngine(manager: audioManager)
        pendingOrpheusEngine = engine

        // Reuse the already-warmed asset if available.
        var preloaded: AVURLAsset? = nil
        if let cached = prefetchedNextAsset, cached.trackID == nextTrack.id {
            preloaded = cached.asset
            prefetchedNextAsset = nil
        }

        pendingOrpheusLoadTask?.cancel()
        pendingOrpheusLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // AUDIT-FIX #16 — one retry after 0.5 s on transient load failures.
            for attempt in 1...2 {
                do {
                    try await engine.load(url: url, headers: headers, startTime: 0,
                                          preloadedAsset: attempt == 1 ? preloaded : nil)
                    guard self.pendingOrpheusEngine === engine else { return }
                    engine.playGapless()
                    ServerLogStore.shared.info("Orpheus: gapless preload active for \(nextTrack.title)")
                    return
                } catch {
                    if attempt == 1 {
                        ServerLogStore.shared.warn(
                            "Orpheus: gapless preload attempt 1 failed (\(error.localizedDescription)), retrying…"
                        )
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled,
                              self.pendingOrpheusEngine === engine else { return }
                    } else {
                        ServerLogStore.shared.warn(
                            "Orpheus: gapless preload failed for \(nextTrack.title): \(error.localizedDescription)"
                        )
                        guard self.pendingOrpheusEngine === engine else { return }
                        self.pendingOrpheusEngine  = nil
                        self.pendingOrpheusLoadTask = nil
                    }
                }
            }
        }
    }

    // MARK: - Orpheus gapless handoff

    /// Transition from the current engine to the pre-loaded pending engine.
    /// The player node never stops — its buffer queue already contains the next
    /// track's audio. We just swap ownership of callbacks and update UI state.
    func performOrpheusGaplessHandoff(pending: OrpheusPlaybackEngine, nextIndex: Int) {
        guard queue.indices.contains(nextIndex) else { nextTrack(); return }
        let track = queue[nextIndex]

        pendingOrpheusLoadTask?.cancel()
        pendingOrpheusLoadTask = nil
        pendingOrpheusEngine   = nil

        // Compute how far the node has played so the new engine's time display
        // starts at 0 rather than the cumulative total.
        let node = audioManager.playerNode
        if let nodeTime = node.lastRenderTime,
           let pt = node.playerTime(forNodeTime: nodeTime),
           pt.sampleTime > 0 {
            pending.configureGaplessSeekOffset(
                nodeElapsedAtHandoff: Double(pt.sampleTime) / pt.sampleRate
            )
        }

        // Stop the current engine's buffer loop without touching the node.
        orpheusEngine?.stopWithoutResettingNode()
        orpheusEngine = pending

        let playbackID   = UUID()
        activePlaybackID = playbackID

        // Update all PlayerViewModel state for the new track.
        currentIndex     = nextIndex
        currentTrack     = track
        duration         = track.duration ?? 0
        currentTime      = 0
        progress         = 0
        isLoading        = false
        isPlaying        = true
        isPaused         = false
        error            = nil
        currentStreamURL = LyrionAPI.shared.streamURLs(for: track).first

        crossfadeTask?.cancel()
        crossfadeTask    = nil
        isCrossfadingOut = false
        radioEarlyFetchTriggered = false

        lmsAudioQualityTask?.cancel()
        lmsAudioQuality = nil

        // Resolve profile for the new track and apply DSP.
        profileManager.update(for: track)
        applyProfileToDSP()

        syncCurrentWorkGroup()
        updateNowPlayingInfo(track: track)
        refreshNowPlayingPlaybackState(force: true)
        LibraryViewModel.shared.recordPlayback(track)
        schedulePlaybackStateSave()

        // Wire up callbacks on the now-active engine.
        pending.onPlaybackEnded = { [weak self] in
            guard let self, self.activePlaybackID == playbackID else { return }
            self.trackDidFinish()
        }
        pending.onTimeUpdate = { [weak self] time in
            guard let self, self.activePlaybackID == playbackID else { return }
            self.currentTime = time
            self.progress    = self.duration > 0 ? min(1, time / self.duration) : 0
            self.refreshNowPlayingPlaybackState()
            self.schedulePlaybackStateSave()
            self.checkScrobbleThreshold(time)
            let remaining = self.duration > 0 ? self.duration - time : 0
            let pm = PlaybackProfileManager.shared
            let cfDur = pm.resolvedCrossfadeDuration
            if pm.resolvedCrossfadeEnabled && cfDur > 0
               && remaining > 0 && remaining <= cfDur && !self.isCrossfadingOut {
                self.startCrossfadeOut()
            }
        }
        pending.onNearEnd = { [weak self] in
            guard let self, self.activePlaybackID == playbackID else { return }
            self.prefetchNextTrackAsset()
            let pm = PlaybackProfileManager.shared
            let cfDur = pm.resolvedCrossfadeDuration
            if pm.resolvedCrossfadeEnabled && cfDur > 0 && !self.isCrossfadingOut {
                self.startCrossfadeOut()
            }
            if pm.resolvedGaplessEnabled && self.pendingOrpheusEngine == nil {
                self.scheduleOrpheusGaplessPreload(for: nextIndex)
            }
        }
        pending.onDurationKnown = { [weak self] dur in
            guard let self, self.activePlaybackID == playbackID else { return }
            self.duration = dur
            self.refreshNowPlayingPlaybackState(force: true)
        }
        pending.onDecodedFormatKnown = { [weak self] fmt in
            guard let self, self.activePlaybackID == playbackID else { return }
            self.orpheusDecodedFormat = fmt
        }
        pending.onError = { [weak self, weak pending] msg in
            guard let self, self.activePlaybackID == playbackID else { return }
            ServerLogStore.shared.warn("Orpheus gapless error: \(msg)")
            self.orpheusFallbackReason = "Gapless error: \(msg)"
            self.isPlaybackRoutedThroughOrpheus = false
            pending?.stop()
            self.orpheusEngine = nil
        }
        pending.onBufferingChanged = { [weak self] buffering in
            guard let self, self.activePlaybackID == playbackID else { return }
            self.isLoading = buffering
        }

        // Mirror engine diagnostics.
        orpheusDidStartAudiblePlayback = true
        isPlaybackRoutedThroughOrpheus = true
        orpheusDecodedFormat  = pending.decodedFormat
        orpheusDurationKnown  = pending.durationKnown
        orpheusCanSeek        = pending.canSeek
        orpheusPlaybackMode   = pending.playbackMode
        orpheusStreamKind     = pending.streamKind

        // Crossfade in if configured, then line up the next-next preload.
        startCrossfadeIn()
        prefetchNextTrackAsset()
        if profileManager.resolvedGaplessEnabled {
            scheduleOrpheusGaplessPreload(for: nextIndex)
        }
        fetchLMSAudioQuality(for: track, playbackID: playbackID)

        ServerLogStore.shared.info("Orpheus: gapless handoff complete → \(track.title)")
    }

    func removeTimeObserver() {
        if let observer = timeObserver {
            // BUG FIX: player can be nil if clearQueue() is called before any
            // track has played.  The original crashed here.  Safe no-op now.
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    func removeItemNotificationObservers() {
        if let token = itemEndObservation {
            NotificationCenter.default.removeObserver(token)
            itemEndObservation = nil
        }
        if let token = itemFailureObservation {
            NotificationCenter.default.removeObserver(token)
            itemFailureObservation = nil
        }
        if let token = itemStalledObservation {
            NotificationCenter.default.removeObserver(token)
            itemStalledObservation = nil
        }
    }

    func installPendingSeekWatchdog() {
        pendingSeekWatchdogTask?.cancel()
        guard pendingSeekTime != nil else { return }
        let capturedID   = activePlaybackID
        let capturedPlay = isPlaying || isPaused

        pendingSeekWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.pendingSeekTime != nil else { return }
            guard capturedID == self.activePlaybackID else { return }
            self.pendingSeekTime = nil
            // If the item itself failed, escalate to the URL fallback chain rather
            // than leaving the UI stuck in a loading state.
            if self.playerItem?.status == .failed,
               self.queue.indices.contains(self.currentIndex) {
                ServerLogStore.shared.warn("Seek watchdog: item failed — triggering URL fallback")
                let track = self.queue[self.currentIndex]
                self.retryNextPlaybackURL(track: track, autoPlay: capturedPlay, playbackID: capturedID)
            }
        }
    }

    func clearPendingSeekWatchdog() {
        pendingSeekWatchdogTask?.cancel()
        pendingSeekWatchdogTask = nil
    }

    // MARK: - Classical metadata resolution

    /// Kicks off a non-blocking resolve of the current track's classical
    /// metadata via ClassicalMetadataResolver. When the resolve completes:
    ///   • currentTrack is reassigned with the populated metadata so
    ///     SwiftUI observers refresh,
    ///   • syncCurrentWorkGroup re-runs so the WORK-tag-driven work group
    ///     can populate.
    /// Also schedules a background prefetch for the next 3 queue items so
    /// the resolver cache is warm before their playback turn.
    func resolveClassicalMetadataForCurrentTrack() {
        guard let track = currentTrack else { return }
        let trackID = track.id

        // Foreground resolve for the current track.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let metadata = await ClassicalMetadataResolver.shared.resolve(trackID: trackID)
            // Stale: a different track is playing now — discard the result.
            guard let current = self.currentTrack, current.id == trackID else { return }
            // No-op if metadata is unchanged (e.g. resolver returned the cached value).
            guard current.classicalMetadata != metadata else { return }

            var updated = current
            updated.classicalMetadata = metadata
            self.currentTrack = updated
            // currentTrack didSet's id-guard skips the play-time side effects;
            // re-derive the work group and refresh lock-screen metadata
            // explicitly now that classical fields are known.
            self.syncCurrentWorkGroup()
            self.updateNowPlayingInfo(track: updated)
        }

        // Background prefetch for upcoming tracks so a fast skip finds them cached.
        let upcoming = upcomingTrackIDsForClassicalPrefetch(count: 3)
        if !upcoming.isEmpty {
            Task { @MainActor in
                await ClassicalMetadataResolver.shared.prefetch(trackIDs: upcoming)
            }
        }
    }

    private func upcomingTrackIDsForClassicalPrefetch(count: Int) -> [Int] {
        let start = currentIndex + 1
        let end = min(start + count, queue.count)
        guard start < end else { return [] }
        return queue[start..<end].map(\.id)
    }

    // MARK: - Internet radio playback
    //
    // Radio runs on a dedicated path so the track/queue/persistence machinery
    // is never involved. currentTrack stays nil; currentRadioStation drives the
    // UI. Reuses the Orpheus engine for streamLike playback, falling back to
    // AVPlayer (which handles ICY radio streams natively) on any failure.

    func playRadioStation(_ station: RadioStation) {
        // Streaming and radio are mutually exclusive — clear stream state first.
        exitStreamForNewPlayback()

        // Preserve the current track session so the Stop button can restore it.
        if currentRadioStation == nil, !queue.isEmpty {
            savedQueueBeforeRadio = queue
            savedIndexBeforeRadio = currentIndex
        }

        // Tear down current track playback manually rather than via clearQueue()
        // — clearQueue() would delete the on-disk snapshot, but we want the
        // pre-radio queue to survive for a later relaunch.
        teardownPlaybackForRadio()

        currentRadioStation = station
        currentStreamURL    = station.streamURL
        duration            = 0
        currentTime         = 0
        progress            = 0
        error               = nil
        isLoading           = true

        startRadioStream(station: station)
        updateNowPlayingInfoForRadio(station: station)
    }

    func stopRadioStation() {
        guard currentRadioStation != nil else { return }
        teardownPlaybackForRadio()
        currentRadioStation = nil
        currentStreamURL    = nil
        isLoading           = false
        isPlaying           = false
        isPaused            = false

        // Restore the pre-radio queue (paused) if we saved one.
        if let saved = savedQueueBeforeRadio, !saved.isEmpty {
            queue = saved
            currentIndex = saved.indices.contains(savedIndexBeforeRadio) ? savedIndexBeforeRadio : 0
            currentTrack = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
            savedQueueBeforeRadio = nil
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        deactivateAudioSession()
    }

    /// Called by the normal play entry points so tapping a library track exits
    /// radio cleanly. The subsequent play path builds its own engine.
    func exitRadioForNewPlayback() {
        guard currentRadioStation != nil else { return }
        orpheusEngine?.stop()
        orpheusEngine = nil
        orpheusLoadTask?.cancel()
        orpheusLoadTask = nil
        currentRadioStation   = nil
        savedQueueBeforeRadio = nil   // user chose new content — discard saved
        currentStreamURL      = nil
        isPlaybackRoutedThroughOrpheus = false
    }

    private func teardownPlaybackForRadio() {
        orpheusEngine?.stop()
        orpheusEngine = nil
        pendingOrpheusEngine?.stop()
        pendingOrpheusEngine = nil
        pendingOrpheusLoadTask?.cancel(); pendingOrpheusLoadTask = nil
        orpheusLoadTask?.cancel();        orpheusLoadTask = nil
        prefetchTask?.cancel();           prefetchTask = nil
        lmsAudioQualityTask?.cancel();    lmsAudioQualityTask = nil
        crossfadeTask?.cancel();          crossfadeTask = nil
        isCrossfadingOut = false
        crossfadeVolume  = 1

        statusObservation?.invalidate();      statusObservation = nil
        durationObservation?.invalidate();    durationObservation = nil
        timeControlObservation?.invalidate(); timeControlObservation = nil
        removeTimeObserver()
        removeItemNotificationObservers()

        audioManager.pause()
        audioManager.replaceCurrentItem(with: nil)
        playerItem = nil

        isPlaybackRoutedThroughOrpheus = false
        gaplessPreloadedItem = nil
        prefetchedNextAsset  = nil

        // Radio replaces the track session in memory but keeps the on-disk
        // snapshot so the pre-radio queue can restore on next launch.
        currentTrack = nil
        queue        = []
        currentIndex = 0
        currentWorkGroup = nil
    }

    private func startRadioStream(station: RadioStation) {
        let url = station.streamURL
        activePlaybackID = UUID()
        let playbackID   = activePlaybackID

        guard activateAudioSession() else {
            isLoading = false
            error = "Could not start audio for radio"
            return
        }

        let routeOutputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        let canUseOrpheus = useOrpheusEngine && !routeOutputs.contains(.airPlay)

        guard canUseOrpheus else {
            startRadioStreamAVPlayer(url: url, playbackID: playbackID)
            return
        }

        let engine = OrpheusPlaybackEngine(manager: audioManager)
        orpheusEngine = engine

        engine.onBufferingChanged = { [weak self] buffering in
            guard let self, playbackID == self.activePlaybackID, self.isPlayingRadio else { return }
            self.isLoading = buffering
        }
        engine.onRoutingConfirmed = { [weak self] confirmed in
            guard let self, playbackID == self.activePlaybackID, self.isPlayingRadio else { return }
            self.isPlaybackRoutedThroughOrpheus = confirmed
            if confirmed { self.isLoading = false }
        }
        engine.onError = { [weak self, weak engine] msg in
            guard let self, playbackID == self.activePlaybackID, self.isPlayingRadio else { return }
            ServerLogStore.shared.warn("Radio Orpheus error: \(msg) — falling back to AVPlayer")
            engine?.stop()
            self.orpheusEngine = nil
            self.isPlaybackRoutedThroughOrpheus = false
            self.startRadioStreamAVPlayer(url: url, playbackID: playbackID)
        }
        engine.onPlaybackEnded = { [weak self] in
            guard let self, playbackID == self.activePlaybackID, self.isPlayingRadio else { return }
            // A live stream "ending" usually means a dropped connection — try
            // AVPlayer, which reconnects ICY streams more gracefully.
            self.orpheusEngine = nil
            self.startRadioStreamAVPlayer(url: url, playbackID: playbackID)
        }

        let headers = LyrionAPI.shared.httpHeaders(accept: "audio/aac,audio/mpeg,audio/ogg,audio/*,*/*")
        orpheusLoadTask?.cancel()
        orpheusLoadTask = Task { @MainActor [weak self] in
            guard let self, self.orpheusEngine === engine, playbackID == self.activePlaybackID else { return }
            do {
                try await engine.load(url: url, headers: headers, startTime: 0)
                guard self.orpheusEngine === engine, playbackID == self.activePlaybackID, self.isPlayingRadio else { return }
                engine.play()
                self.isPlaying = true
                self.isPaused  = false
                self.refreshNowPlayingPlaybackState(force: true)
            } catch {
                guard playbackID == self.activePlaybackID, self.isPlayingRadio else { return }
                self.orpheusEngine = nil
                self.startRadioStreamAVPlayer(url: url, playbackID: playbackID)
            }
        }
    }

    private func startRadioStreamAVPlayer(url: URL, playbackID: UUID) {
        guard playbackID == activePlaybackID, isPlayingRadio else { return }
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": LyrionAPI.shared.httpHeaders(accept: "audio/aac,audio/mpeg,audio/ogg,audio/*,*/*")
        ])
        let item = AVPlayerItem(asset: asset)
        playerItem = item
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] obsItem, _ in
            Task { @MainActor [weak self] in
                guard let self, playbackID == self.activePlaybackID, self.isPlayingRadio else { return }
                switch obsItem.status {
                case .readyToPlay:
                    self.isLoading = false
                case .failed:
                    self.isLoading = false
                    self.error = "Radio stream unavailable"
                    ServerLogStore.shared.error("Radio AVPlayer failed: \(obsItem.error?.localizedDescription ?? "unknown")")
                default:
                    break
                }
            }
        }
        audioManager.replaceCurrentItem(with: item)
        player.volume = volume * crossfadeVolume
        player.play()
        isPlaybackRoutedThroughOrpheus = false
        isPlaying = true
        isPaused  = false
        refreshNowPlayingPlaybackState(force: true)
    }
}
