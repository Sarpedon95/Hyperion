// ADDED: extracted from PlayerViewModel.swift — lock-screen remote controls + MPNowPlayingInfoCenter
import AVFoundation
import MediaPlayer
import UIKit
import WidgetKit

extension PlayerViewModel {

    // MARK: - Lock screen / remote controls

    func setupRemoteControls() {
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)

        MPNowPlayingInfoCenter.default().playbackState = .stopped

        cc.playCommand.isEnabled            = true
        cc.pauseCommand.isEnabled           = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled       = true
        cc.previousTrackCommand.isEnabled   = true
        cc.changePlaybackPositionCommand.isEnabled = true

        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ServerLogStore.shared.debug("Remote: Play command")
                self.resume()
            }
            return .success
        }

        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ServerLogStore.shared.debug("Remote: Pause command")
                self.pause()
            }
            return .success
        }

        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ServerLogStore.shared.debug("Remote: Toggle play/pause")
                self.togglePlayPause()
            }
            return .success
        }

        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ServerLogStore.shared.debug("Remote: Next track")
                self.nextTrack()
            }
            return .success
        }

        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ServerLogStore.shared.debug("Remote: Previous track")
                self.previousTrack()
            }
            return .success
        }

        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor [weak self] in
                guard let self else { return }
                ServerLogStore.shared.debug("Remote: Seek to \(String(format: "%.1f", position))s")
                self.seek(to: position)
            }
            return .success
        }

        cc.skipForwardCommand.isEnabled  = false
        cc.skipBackwardCommand.isEnabled = false
        ServerLogStore.shared.debug("Remote controls registered")
    }

    // MARK: - Now Playing Info

    func updateNowPlayingInfo(track: Track?) {
        let artworkURL = track.flatMap { LyrionAPI.shared.artworkURL(coverid: $0.coverid) }
        NowPlayingWidgetStore.shared.update(track: track, isPlaying: isPlaying, artworkURL: artworkURL)

        // ADDED: Task 9 — kick off accent colour extraction for the new track's artwork.
        accentColorExtractionTask?.cancel()
        if let artURL = artworkURL {
            accentColorExtractionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image = await self.loadImage(from: artURL, targetPoints: 80) else { return }
                guard !Task.isCancelled else { return }
                let color = await ArtworkColorExtractor.shared.extract(from: image)
                guard !Task.isCancelled else { return }
                self.accentColor = color
            }
        } else {
            accentColor = .roonAccent
        }

        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        artworkLoadID += 1
        let loadID  = artworkLoadID
        let trackID = track.id

        var info: [String: Any] = [
            MPMediaItemPropertyTitle:              track.title,
            MPMediaItemPropertyArtist:             track.trackartist ?? track.albumartist ?? "",
            MPMediaItemPropertyAlbumTitle:         track.album ?? "",
            MPMediaItemPropertyComposer:           track.composer ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration:   duration,
            MPNowPlayingInfoPropertyPlaybackRate:        isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType:     MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count
        ]
        info[MPMediaItemPropertyAlbumTrackNumber] = track.tracknum ?? 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : (isPaused ? .paused : .stopped)

        guard let coverid = track.coverid,
              let artURL  = LyrionAPI.shared.artworkURL(coverid: coverid) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // FIXED: use window scene bounds instead of deprecated UIScreen.main.bounds
            let screenSize = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.screen.bounds.size ?? CGSize(width: 390, height: 844)
            let targetPts  = max(screenSize.width, screenSize.height)
            guard let image = await self.loadImage(from: artURL, targetPoints: targetPts) else { return }
            guard self.artworkLoadID == loadID, self.currentTrack?.id == trackID else { return }
            let artwork = MPMediaItemArtwork(boundsSize: screenSize) { _ in image }
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            updated[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }

    func refreshNowPlayingPlaybackState(force: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        if !force, uptime - lastNowPlayingRefreshUptime < 1.0 { return }
        lastNowPlayingRefreshUptime = uptime

        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : (isPaused ? .paused : .stopped)

        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration]         = duration > 0 ? duration : (currentTrack?.duration ?? 0)
        info[MPNowPlayingInfoPropertyPlaybackRate]        = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex]  = currentIndex
        info[MPNowPlayingInfoPropertyPlaybackQueueCount]  = queue.count
        MPNowPlayingInfoCenter.default().nowPlayingInfo   = info
    }
}
