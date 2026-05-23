// PlayerViewModel+Streaming.swift
// Hyperion — Streaming playback (Qobuz / Deezer)
//
// Streaming runs through the same OrpheusPlaybackEngine that handles radio
// streams, so DSP, lock-screen artwork, and route changes all behave exactly
// like local playback. The track/queue/persistence machinery for local
// content is bypassed: streaming uses its own `streamQueue` and surfaces
// the now-playing track via `currentStreamTrack` so the local AVPlayer/LMS
// path is never touched.

import Foundation
import AVFoundation
import MediaPlayer
import UIKit

extension PlayerViewModel {

    // MARK: - Public API

    /// Resolve the stream URL via PlaybackRouter and start playback on the
    /// Orpheus engine. Replaces any running radio or local track. No-op for
    /// non-admin users.
    func playStreamTrack(_ track: StreamTrack) async {
        guard UserSession.shared.isAdmin else { return }

        // Replace existing playback (radio + local).
        if isPlayingRadio { stopRadioStation() }
        teardownLocalPlaybackForStream()

        // Mark loading + show the new track in the UI before the URL resolves
        // so the mini-player flips to the right artwork immediately.
        currentStreamTrack = track
        if streamQueue.isEmpty || streamQueue[safe: streamQueueIndex]?.id != track.id {
            streamQueue = [track]
            streamQueueIndex = 0
        }
        duration    = track.duration
        currentTime = 0
        progress    = 0
        isLoading   = true
        error       = nil
        updateNowPlayingInfoForStreamTrack(track)

        do {
            let url = try await PlaybackRouter.shared.resolveStreamURL(for: track)
            startStreamPlayback(url: url, track: track)
        } catch {
            ServerLogStore.shared.warn("[Streaming] resolve failed for \(track.title): \(error.localizedDescription)")
            isLoading = false
            self.error = "Stream unavailable"
        }
    }

    /// Queue another stream track. If nothing is playing yet, the queued track
    /// will not auto-start — call playStreamTrack() to begin.
    func addStreamTrackToQueue(_ track: StreamTrack) async {
        guard UserSession.shared.isAdmin else { return }
        streamQueue.append(track)
    }

    /// Called by the normal local-play entry points so tapping a library track
    /// exits streaming cleanly. The subsequent play path builds its own engine.
    func exitStreamForNewPlayback() {
        guard currentStreamTrack != nil else { return }
        orpheusEngine?.stop()
        orpheusEngine = nil
        orpheusLoadTask?.cancel()
        orpheusLoadTask = nil
        currentStreamTrack = nil
        streamQueue = []
        streamQueueIndex = 0
        currentStreamURL = nil
        isPlaybackRoutedThroughOrpheus = false
    }

    /// Stop the active stream and clear stream state. Safe to call when no
    /// stream is playing.
    func stopStreamPlayback() {
        guard currentStreamTrack != nil else { return }
        orpheusEngine?.stop()
        orpheusEngine = nil
        orpheusLoadTask?.cancel()
        orpheusLoadTask = nil
        currentStreamTrack = nil
        streamQueue = []
        streamQueueIndex = 0
        currentStreamURL = nil
        isPlaybackRoutedThroughOrpheus = false
        isPlaying = false
        isPaused  = false
        isLoading = false
        duration = 0
        currentTime = 0
        progress = 0
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
    }

    // MARK: - Engine wiring

    private func startStreamPlayback(url: URL, track: StreamTrack) {
        activePlaybackID = UUID()
        let playbackID   = activePlaybackID

        guard activateAudioSession() else {
            isLoading = false
            error = "Could not start audio for streaming"
            return
        }

        currentStreamURL = url

        // Tear down any prior engine before starting a new one.
        orpheusLoadTask?.cancel()
        orpheusLoadTask = nil
        orpheusEngine?.stop()

        let engine = OrpheusPlaybackEngine(manager: audioManager)
        orpheusEngine = engine

        engine.onDurationKnown = { [weak self] dur in
            guard let self, playbackID == self.activePlaybackID,
                  self.currentStreamTrack?.id == track.id else { return }
            self.duration = dur
            self.refreshNowPlayingPlaybackState(force: true)
        }
        engine.onBufferingChanged = { [weak self] buffering in
            guard let self, playbackID == self.activePlaybackID,
                  self.currentStreamTrack?.id == track.id else { return }
            self.isLoading = buffering
        }
        engine.onTimeUpdate = { [weak self] time in
            guard let self, playbackID == self.activePlaybackID,
                  self.currentStreamTrack?.id == track.id else { return }
            self.currentTime = time
            self.progress    = self.duration > 0 ? min(1, time / self.duration) : 0
            self.refreshNowPlayingPlaybackState()
        }
        engine.onRoutingConfirmed = { [weak self] confirmed in
            guard let self, playbackID == self.activePlaybackID,
                  self.currentStreamTrack?.id == track.id else { return }
            self.isPlaybackRoutedThroughOrpheus = confirmed
            if confirmed { self.isLoading = false }
        }
        engine.onPlaybackEnded = { [weak self] in
            guard let self, playbackID == self.activePlaybackID,
                  self.currentStreamTrack?.id == track.id else { return }
            self.streamTrackDidFinish()
        }
        engine.onError = { [weak self, weak engine] msg in
            guard let self, playbackID == self.activePlaybackID,
                  self.currentStreamTrack?.id == track.id else { return }
            ServerLogStore.shared.warn("[Streaming] Orpheus error: \(msg)")
            engine?.stop()
            self.orpheusEngine = nil
            self.isPlaybackRoutedThroughOrpheus = false
            self.isLoading = false
            self.error = "Stream playback failed"
        }

        let headers: [String: String] = [:]
        orpheusLoadTask = Task { @MainActor [weak self] in
            guard let self, self.orpheusEngine === engine,
                  playbackID == self.activePlaybackID else { return }
            do {
                try await engine.load(url: url, headers: headers, startTime: 0)
                guard self.orpheusEngine === engine,
                      playbackID == self.activePlaybackID,
                      self.currentStreamTrack?.id == track.id else { return }
                engine.play()
                self.isPlaying = true
                self.isPaused  = false
                self.refreshNowPlayingPlaybackState(force: true)
            } catch {
                guard playbackID == self.activePlaybackID,
                      self.currentStreamTrack?.id == track.id else { return }
                ServerLogStore.shared.warn("[Streaming] Orpheus load failed: \(error.localizedDescription)")
                self.orpheusEngine = nil
                self.isLoading = false
                self.error = "Stream load failed"
            }
        }
    }

    private func streamTrackDidFinish() {
        advanceStreamQueueOrStop()
    }

    /// Skip to the next entry in the stream queue, or tear down if at the end.
    /// Invoked by both the engine's onPlaybackEnded callback and the mini /
    /// Now Playing "Next" button.
    func advanceStreamQueueOrStop() {
        let next = streamQueueIndex + 1
        guard streamQueue.indices.contains(next) else {
            stopStreamPlayback()
            return
        }
        streamQueueIndex = next
        let track = streamQueue[next]
        Task { await self.playQueuedStreamTrack(track) }
    }

    private func playQueuedStreamTrack(_ track: StreamTrack) async {
        currentStreamTrack = track
        duration    = track.duration
        currentTime = 0
        progress    = 0
        isLoading   = true
        error       = nil
        updateNowPlayingInfoForStreamTrack(track)

        do {
            let url = try await PlaybackRouter.shared.resolveStreamURL(for: track)
            startStreamPlayback(url: url, track: track)
        } catch {
            ServerLogStore.shared.warn("[Streaming] queue advance failed for \(track.title): \(error.localizedDescription)")
            // Skip this track and try the next one.
            streamTrackDidFinish()
        }
    }

    /// Tear down any active local-track playback before a stream starts.
    /// Mirrors exitRadioForNewPlayback() but for the local path.
    private func teardownLocalPlaybackForStream() {
        guard currentTrack != nil || !queue.isEmpty else { return }
        orpheusEngine?.stop()
        orpheusEngine = nil
        orpheusLoadTask?.cancel()
        orpheusLoadTask = nil
        audioManager.pause()
        audioManager.replaceCurrentItem(with: nil)
        playerItem = nil
        currentTrack = nil
        queue = []
        currentIndex = 0
        currentWorkGroup = nil
        isPlaybackRoutedThroughOrpheus = false
    }

    // MARK: - Now Playing info

    private func updateNowPlayingInfoForStreamTrack(_ track: StreamTrack) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:       track.title,
            MPMediaItemPropertyArtist:      track.artist,
            MPMediaItemPropertyAlbumTitle:  track.album,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if track.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = track.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard let artworkURL = track.artworkURL else { return }
        Task { [weak self] in
            guard let data = try? await URLSession.shared.data(from: artworkURL).0,
                  let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard let self,
                      self.currentStreamTrack?.id == track.id else { return }
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
                updated[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Unified search result model

struct SearchResultSection: Identifiable {
    let id: String
    let title: String       // "Qobuz", "Deezer"
    let source: StreamSourceType
    let tracks: [StreamTrack]
    let albums: [StreamAlbum]
}
