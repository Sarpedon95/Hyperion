// ADDED: extracted from PlayerViewModel.swift — queue management + artwork loading
import AVFoundation
import MediaPlayer
import UIKit

extension PlayerViewModel {

    // MARK: - Queue management

    func clearQueue() {
        orpheusEngine?.stop()
        orpheusEngine = nil
        pendingOrpheusEngine?.stop()
        pendingOrpheusEngine = nil
        pendingOrpheusLoadTask?.cancel()
        pendingOrpheusLoadTask = nil
        isPlaybackRoutedThroughOrpheus = false
        orpheusDidStartAudiblePlayback = false
        orpheusDecodedFormat  = ""
        orpheusDurationKnown  = false
        orpheusCanSeek        = false
        orpheusPlaybackMode   = .fileLike
        orpheusStreamKind     = .unknown
        orpheusFallbackReason = nil

        profileManager.clearSessionOverrides()
        pendingSeekWatchdogTask?.cancel();    pendingSeekWatchdogTask    = nil
        playbackStartupWatchdogTask?.cancel(); playbackStartupWatchdogTask = nil
        prefetchTask?.cancel();               prefetchTask               = nil
        lmsAudioQualityTask?.cancel();        lmsAudioQualityTask        = nil
        accentColorExtractionTask?.cancel();  accentColorExtractionTask  = nil
        accentColor = .roonAccent
        crossfadeTask?.cancel();              crossfadeTask              = nil
        isCrossfadingOut         = false
        crossfadeVolume          = 1
        gaplessPreloadedItem     = nil
        radioEarlyFetchTriggered = false

        statusObservation?.invalidate();      statusObservation      = nil
        durationObservation?.invalidate();    durationObservation    = nil
        timeControlObservation?.invalidate(); timeControlObservation = nil

        audioManager.pause()
        audioManager.replaceCurrentItem(with: nil)
        playerItem = nil
        removeTimeObserver()
        removeItemNotificationObservers()

        pendingSeekTime              = nil
        playbackURLCandidates        = []
        playbackURLIndex             = 0
        lastPlaybackErrorDescription = nil
        activePlaybackID             = UUID()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        endBackgroundPlaybackTask()

        isPlaying = false
        isPaused  = false
        deactivateAudioSession(force: true)
        PlaybackStateStore.shared.clear()

        queue                      = []
        currentIndex               = 0
        currentTrack               = nil
        currentWorkGroup           = nil
        artworkLoadID             += 1
        currentTime                = 0
        duration                   = 0
        progress                   = 0
        error                      = nil
        isLoading                  = false
        isShuffle                  = false
        originalQueueBeforeShuffle = nil
        lmsAudioQuality            = nil
        currentStreamURL           = nil
        sourceFormat               = ""
        outputFormat               = ""
        outputDeviceName           = ""
        isBitPerfect               = false
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if queue.isEmpty { clearQueue(); return }
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(currentIndex, queue.count - 1)
            currentTrack = queue[currentIndex]
            syncCurrentWorkGroup()
            if isPlaying { playCurrentTrack() } else if isPaused { playCurrentTrack(autoPlay: false) }
        }
        if originalQueueBeforeShuffle != nil {
            originalQueueBeforeShuffle = filteredOriginalQueuePreservingCounts()
        }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let sortedSource = source.sorted().filter { queue.indices.contains($0) }
        guard !sortedSource.isEmpty else { return }

        let oldCurrentIndex    = currentIndex
        let sourceSet          = Set(sortedSource)
        let movingTracks       = sortedSource.map { queue[$0] }
        let currentWasMoved    = sourceSet.contains(oldCurrentIndex)
        let movedCurrentOffset = currentWasMoved ? sortedSource.firstIndex(of: oldCurrentIndex) : nil

        var remaining = queue.enumerated()
            .filter { !sourceSet.contains($0.offset) }
            .map { $0.element }

        let removedBeforeDestination = sortedSource.filter { $0 < destination }.count
        let insertionIndex = max(0, min(remaining.count, destination - removedBeforeDestination))
        remaining.insert(contentsOf: movingTracks, at: insertionIndex)
        queue = remaining

        if queue.isEmpty {
            currentIndex = 0
        } else if currentWasMoved, let movedCurrentOffset {
            currentIndex = max(0, min(queue.count - 1, insertionIndex + movedCurrentOffset))
        } else {
            let removedBeforeCurrent = sortedSource.filter { $0 < oldCurrentIndex }.count
            var newCurrentIndex = oldCurrentIndex - removedBeforeCurrent
            if insertionIndex <= newCurrentIndex { newCurrentIndex += movingTracks.count }
            currentIndex = max(0, min(queue.count - 1, newCurrentIndex))
        }
        syncCurrentWorkGroup()
        if originalQueueBeforeShuffle != nil {
            originalQueueBeforeShuffle = filteredOriginalQueuePreservingCounts()
        }
        prefetchNextTrackAsset()
    }

    // MARK: - Artwork (delegates to ArtworkCache)

    func loadImage(from url: URL, targetPoints: CGFloat = 600) async -> UIImage? {
        let scale: CGFloat
        if #available(iOS 17.0, *) {
            scale = UITraitCollection.current.displayScale > 0
                ? UITraitCollection.current.displayScale : 2.0
        } else {
            scale = UITraitCollection.current.displayScale > 0
                ? UITraitCollection.current.displayScale : UIScreen.main.scale
        }
        return await ArtworkCache.shared.loadImage(url: url, targetPoints: targetPoints, scale: scale)
    }
}
