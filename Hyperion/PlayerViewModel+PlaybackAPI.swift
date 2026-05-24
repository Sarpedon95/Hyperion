// ADDED: extracted from PlayerViewModel.swift — all public playback entry points
import AVFoundation
import MediaPlayer

extension PlayerViewModel {

    // MARK: - Public playback API

    func playWork(_ workGroup: WorkGroup) {
        playWork(workGroup, startingAt: 0)
    }

    func playWork(_ workGroup: WorkGroup, startingAt index: Int) {
        guard !workGroup.tracks.isEmpty else { return }
        exitRadioForNewPlayback()
        exitStreamForNewPlayback()
        originalQueueBeforeShuffle = nil
        isShuffle        = false
        currentWorkGroup = workGroup
        queue            = workGroup.tracks
        currentIndex     = max(0, min(index, workGroup.tracks.count - 1))
        playCurrentTrack()
    }

    func playAlbum(_ workGroups: [WorkGroup]) {
        let tracks = workGroups.flatMap(\.tracks)
        guard !tracks.isEmpty else { return }
        exitRadioForNewPlayback()
        exitStreamForNewPlayback()
        originalQueueBeforeShuffle = nil
        isShuffle        = false
        currentWorkGroup = workGroups.first
        queue            = tracks
        currentIndex     = 0
        playCurrentTrack()
    }

    func playSingleTrack(_ track: Track) {
        exitRadioForNewPlayback()
        exitStreamForNewPlayback()
        originalQueueBeforeShuffle = nil
        isShuffle        = false
        currentWorkGroup = nil
        queue            = [track]
        currentIndex     = 0
        playCurrentTrack()
    }

    func playTracks(_ tracks: [Track], startingAt index: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        exitRadioForNewPlayback()
        exitStreamForNewPlayback()
        originalQueueBeforeShuffle = nil
        isShuffle        = false
        currentWorkGroup = nil
        queue            = tracks
        currentIndex     = max(0, min(index, tracks.count - 1))
        if shuffle && tracks.count > 1 {
            originalQueueBeforeShuffle = tracks
            let current = queue[currentIndex]
            var remaining = queue
            remaining.remove(at: currentIndex)
            remaining.shuffle()
            queue = [current] + remaining
            currentIndex = 0
            isShuffle = true
        }
        playCurrentTrack()
    }

    func addWorkToQueue(_ workGroup: WorkGroup) {
        addWorkGroupsToQueue([workGroup])
    }

    func addWorkGroupsToQueue(_ workGroups: [WorkGroup]) {
        let tracks = workGroups.flatMap(\.tracks)
        guard !tracks.isEmpty else { return }
        queue.append(contentsOf: tracks)
        if let original = originalQueueBeforeShuffle {
            originalQueueBeforeShuffle = original + tracks
        }
    }

    func addTracksToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        queue.append(contentsOf: tracks)
        if let original = originalQueueBeforeShuffle {
            originalQueueBeforeShuffle = original + tracks
        }
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(contentsOf: tracks, at: insertAt)
        if let original = originalQueueBeforeShuffle {
            originalQueueBeforeShuffle = original + tracks
        }
        prefetchNextTrackAsset()
    }

    func playTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        exitRadioForNewPlayback()
        exitStreamForNewPlayback()
        currentIndex = index
        syncCurrentWorkGroup()
        playCurrentTrack()
    }

    func pause() {
        ServerLogStore.shared.debug("Pause called")
        if let engine = orpheusEngine { engine.pause() } else { audioManager.pause() }
        isPlaying = false
        isPaused  = true
        isTransitioningPlayback = false
        endBackgroundPlaybackTask()
        MPNowPlayingInfoCenter.default().playbackState = .paused
        refreshNowPlayingPlaybackState(force: true)
        NowPlayingWidgetStore.shared.update(track: currentTrack, isPlaying: false)
    }

    func resume() {
        guard currentTrack != nil || !queue.isEmpty || isPlayingStream else {
            ServerLogStore.shared.debug("Resume: No track or queue available")
            return
        }

        if let engine = orpheusEngine {
            guard activateAudioSession() else { return }
            if isPaused { engine.resume() } else { engine.play() }
            isPlaying = true
            isPaused  = false
            MPNowPlayingInfoCenter.default().playbackState = .playing
            refreshNowPlayingPlaybackState(force: true)
            return
        }

        if player.currentItem == nil, queue.indices.contains(currentIndex) {
            ServerLogStore.shared.debug("Resume: No player item, starting from track \(currentIndex)")
            playCurrentTrack()
            return
        }

        guard activateAudioSession() else {
            ServerLogStore.shared.error("Resume: Failed to activate audio session")
            isPlaying = false
            return
        }

        let isInBackground = UIApplication.shared.applicationState != .active
        ServerLogStore.shared.info("Resume: starting from \(isInBackground ? "background" : "foreground")")
        if isInBackground && backgroundTaskID == .invalid {
            beginBackgroundPlaybackTask(reason: "resume-background")
        }
        startPlayer(preferImmediateStart: isInBackground)
        isPlaying = true
        isPaused  = false
        refreshNowPlayingPlaybackState(force: true)
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func togglePlayPause() {
        guard !isTransitioningPlayback else { return }
        isTransitioningPlayback = true
        if isPlaying { pause() } else { resume() }
        forwardToLMSPlayer { dir in await dir.remotePlayPause() }
        playbackToggleDebounceTask?.cancel()
        playbackToggleDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.isTransitioningPlayback = false
        }
    }

    func nextTrack() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSkipTimestamp >= 0.15 else { return }
        lastSkipTimestamp = now

        // Streaming uses its own queue and runs on a dedicated engine path.
        if isPlayingStream {
            advanceStreamQueueOrStop()
            return
        }

        guard !queue.isEmpty else { return }
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            playCurrentTrack()
        } else if repeatMode == 2 {
            currentIndex = 0
            playCurrentTrack()
        }
        forwardToLMSPlayer { dir in await dir.remoteNext() }
    }

    func previousTrack() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSkipTimestamp >= 0.15 else { return }
        lastSkipTimestamp = now
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            refreshNowPlayingPlaybackState(force: true)
            return
        }
        guard currentIndex > 0 else { seek(to: 0); return }
        currentIndex -= 1
        playCurrentTrack()
        forwardToLMSPlayer { dir in await dir.remotePrevious() }
    }

    // MARK: - LMS hardware-player forwarding (audit phase 7)
    //
    // Additive: when the user picks an LMS hardware player in Settings,
    // these forwarders fire the matching slim.request on that device so
    // it stays in lock-step with Hyperion's local transport. The local
    // AVPlayer/Orpheus path is unchanged.
    fileprivate func forwardToLMSPlayer(_ action: @Sendable @escaping (LMSPlayerDirectory) async -> Bool) {
        let directory = LMSPlayerDirectory.shared
        guard directory.isRoutingToHardware else { return }
        Task { @MainActor in _ = await action(directory) }
    }

    func seek(to time: Double) {
        let clamped = duration > 0 ? max(0, min(duration, time)) : max(0, time)

        if isPlaybackRoutedThroughOrpheus {
            orpheusEngine?.seek(to: clamped)
            currentTime = clamped
            progress    = duration > 0 ? clamped / duration : 0
            refreshNowPlayingPlaybackState(force: true)
            return
        }

        if let item = playerItem, item.status == .readyToPlay {
            clearPendingSeekWatchdog()
            pendingSeekTime = nil
            player.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter:  .zero
            )
        } else {
            pendingSeekTime = clamped
            installPendingSeekWatchdog()
        }

        currentTime = clamped
        progress    = duration > 0 ? clamped / duration : 0
        refreshNowPlayingPlaybackState(force: true)
    }

    func setVolume(_ value: Float) {
        volume = max(0, min(1, value))
        let snapshot = volume
        forwardToLMSPlayer { dir in await dir.remoteSetVolume(snapshot) }
    }

    func toggleShuffle() {
        if isShuffle {
            if let restored = filteredOriginalQueuePreservingCounts() {
                let playingTrack = currentTrack
                queue = restored
                if let playingTrack,
                   let restoredIndex = queue.firstIndex(where: { $0.id == playingTrack.id }) {
                    currentIndex = restoredIndex
                }
            }
            isShuffle                  = false
            originalQueueBeforeShuffle = nil
            return
        }

        guard !queue.isEmpty else { return }
        guard queue.indices.contains(currentIndex) else { currentIndex = 0; return }

        originalQueueBeforeShuffle = queue
        isShuffle = true
        let current   = queue[currentIndex]
        var remaining = queue
        remaining.remove(at: currentIndex)
        remaining.shuffle()
        queue        = [current] + remaining
        currentIndex = 0
    }

    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3 }

    // MARK: - Radio mode

    func startRadio(seed: Track) {
        exitRadioForNewPlayback()
        exitStreamForNewPlayback()
        radioSeed = seed
        isRadioEnabled = true
        originalQueueBeforeShuffle = nil
        isShuffle = false
        currentWorkGroup = nil
        queue = [seed]
        currentIndex = 0
        playCurrentTrack()
        fetchRadioTracks()
    }

    func stopRadio() {
        isRadioEnabled = false
        radioSeed = nil
        radioRefreshTask?.cancel()
        radioRefreshTask = nil
    }

    func filteredOriginalQueuePreservingCounts() -> [Track]? {
        guard let original = originalQueueBeforeShuffle else { return nil }
        var remainingCounts: [Int: Int] = [:]
        for track in queue { remainingCounts[track.id, default: 0] += 1 }
        var filtered: [Track] = []
        filtered.reserveCapacity(queue.count)
        for track in original {
            guard let count = remainingCounts[track.id], count > 0 else { continue }
            filtered.append(track)
            remainingCounts[track.id] = count - 1
        }
        return filtered
    }
}
