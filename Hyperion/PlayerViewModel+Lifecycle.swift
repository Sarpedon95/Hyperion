// ADDED: extracted from PlayerViewModel.swift — audio session, app lifecycle, audio observers
import AVFoundation
import UIKit

extension PlayerViewModel {

    // MARK: - Audio session

    func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            lastPlaybackErrorDescription = error.localizedDescription
            ServerLogStore.shared.error("Audio session setup failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func activateAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            logAudioSessionState("activated")
            return true
        } catch {
            lastPlaybackErrorDescription = error.localizedDescription
            self.error = "Audio playback unavailable. Please check your device settings and try again."
            ServerLogStore.shared.error("Audio session activation failed: \(error.localizedDescription)")
            return false
        }
    }

    func deactivateAudioSession(force: Bool = false) {
        guard force || !isPlaying else { return }
        endBackgroundPlaybackTask()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            ServerLogStore.shared.debug("Audio session deactivated")
        } catch {
            ServerLogStore.shared.error("Audio session deactivation failed: \(error.localizedDescription)")
        }
    }

    func logAudioSessionState(_ label: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        ServerLogStore.shared.debug(
            "Audio session state [\(label)]: category=\(session.category.rawValue), mode=\(session.mode.rawValue), sampleRate=\(Int(session.sampleRate)), outputs=\(outputs.isEmpty ? "none" : outputs)"
        )
    }

    func describeTimeControlStatus(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waitingToPlayAtSpecifiedRate"
        case .playing: return "playing"
        @unknown default: return "unknown"
        }
    }

    func describeItemStatus(_ item: AVPlayerItem?) -> String {
        guard let item else { return "nil" }
        switch item.status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed(\(item.error?.localizedDescription ?? "unknown error"))"
        @unknown default: return "unknown"
        }
    }

    func handleScenePhaseChange(_ phaseName: String) {
        ServerLogStore.shared.info("SwiftUI scenePhase changed: \(phaseName), isPlaying=\(isPlaying), player=\(describeTimeControlStatus(player.timeControlStatus)), item=\(describeItemStatus(playerItem))")
        if phaseName == "background", isPlaying {
            isHandlingBackgroundTransition = true
            beginBackgroundPlaybackTask(reason: "scene-phase-background")
            if activateAudioSession() && !isPlaybackRoutedThroughOrpheus {
                startPlayer(preferImmediateStart: true)
            }
            refreshNowPlayingPlaybackState(force: true)
        }
    }

    // MARK: - App lifecycle / background playback

    func setupAppLifecycleObservers() {
        let center = NotificationCenter.default

        // IMPORTANT: use queue: .main with a synchronous main-actor hop — NOT
        // Task { @MainActor }. iOS determines whether to keep the process alive
        // based on what happens during didEnterBackground delivery. Deferring
        // activation/playback until after the notification returns can allow the
        // process to be suspended before the audio session is reconfirmed.
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleDidEnterBackground()
            }
        })

        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleWillEnterForeground()
            }
        })

        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleWillTerminate()
            }
        })

        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleWillResignActive()
            }
        })
    }

    func handleWillResignActive() {
        guard isPlaying else { return }
        isHandlingBackgroundTransition = true
        savePlaybackStateNow()
        beginBackgroundPlaybackTask(reason: "will-resign-active")
        if activateAudioSession() && !isPlaybackRoutedThroughOrpheus {
            startPlayer(preferImmediateStart: true)
        }
        refreshNowPlayingPlaybackState(force: true)
    }

    func handleDidEnterBackground() {
        let orpheusIsAudiblyPlaying = isPlaybackRoutedThroughOrpheus && (orpheusEngine?.isPlaying == true)
        let playerIsAudiblyPlaying  = player.rate > 0 || player.timeControlStatus == .playing || orpheusIsAudiblyPlaying

        guard isPlaying || playerIsAudiblyPlaying else {
            savePlaybackStateNow()
            ServerLogStore.shared.debug("Entered background (not playing)")
            isHandlingBackgroundTransition = false
            endBackgroundPlaybackTask()
            refreshNowPlayingPlaybackState(force: true)
            return
        }

        if playerIsAudiblyPlaying && !isPlaying {
            isPlaying = true
            isPaused = false
        }

        ServerLogStore.shared.info("Entered background (playing)")
        savePlaybackStateNow()
        beginBackgroundPlaybackTask(reason: "background-transition")

        guard activateAudioSession() else {
            endBackgroundPlaybackTask()
            isHandlingBackgroundTransition = false
            ServerLogStore.shared.error("Failed to activate audio session in background")
            isPlaying = false
            refreshNowPlayingPlaybackState(force: true)
            return
        }

        if isPlaybackRoutedThroughOrpheus {
            ServerLogStore.shared.info("Background: Orpheus engine active — AVAudioEngine owns background continuity")
        } else {
            let itemStatus = describeItemStatus(playerItem)
            let playerTimeControl = describeTimeControlStatus(player.timeControlStatus)
            ServerLogStore.shared.debug("Background transition: item=\(itemStatus), control=\(playerTimeControl)")
            if playerItem?.status == .readyToPlay {
                startPlayer(preferImmediateStart: true)
                ServerLogStore.shared.info("Background: Continued playback immediately (item ready)")
            } else {
                ServerLogStore.shared.debug("Background: Waiting for item readiness before playback")
            }
        }
        refreshNowPlayingPlaybackState(force: true)
    }

    func handleWillEnterForeground() {
        isHandlingBackgroundTransition = false
        if isPlaying { activateAudioSession() }
        endBackgroundPlaybackTask()
        refreshNowPlayingPlaybackState(force: true)
    }

    func handleWillTerminate() {
        savePlaybackStateNow()
        refreshNowPlayingPlaybackState(force: true)
        endBackgroundPlaybackTask()
    }

    func beginBackgroundPlaybackTask(reason: String) {
        guard backgroundTaskID == .invalid else {
            ServerLogStore.shared.debug("Background task already active, skipping duplicate request")
            return
        }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "HyperionAudio-\(reason)",
            expirationHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    ServerLogStore.shared.warn("Background task expired while \(reason); ending task without pausing audio")
                    self.endBackgroundPlaybackTask()
                    if self.isPlaying {
                        _ = self.activateAudioSession()
                        if !self.isPlaybackRoutedThroughOrpheus {
                            self.startPlayer(preferImmediateStart: true)
                        }
                    }
                }
            }
        )
        ServerLogStore.shared.debug("Background task started: \(reason)")
    }

    func endBackgroundPlaybackTask() {
        guard backgroundTaskID != .invalid else { return }
        let taskID = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
    }

    // MARK: - Audio observers

    func setupAudioObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleInterruption(notification) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleRouteChange(notification) }
        }
    }

    func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw  = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type     = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            ServerLogStore.shared.debug("Audio session: Received malformed interruption notification")
            return
        }

        let reasonDescription: String
        if let reasonRaw = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt {
            if let reason = AVAudioSession.InterruptionReason(rawValue: reasonRaw) {
                reasonDescription = "\(reason)"
            } else {
                reasonDescription = "raw=\(reasonRaw)"
            }
        } else {
            reasonDescription = "none"
        }
        ServerLogStore.shared.info("Audio session interruption notification: type=\(type), reason=\(reasonDescription), appState=\(UIApplication.shared.applicationState.rawValue), isPlaying=\(isPlaying)")
        logAudioSessionState("interruption-\(type)")

        switch type {
        case .began:
            ServerLogStore.shared.debug("Audio session: Interruption began")
            wasPlayingBeforeInterruption = isPlaying
            if shouldIgnoreBackgroundInterruption(userInfo) {
                ServerLogStore.shared.debug("Audio session: Background transition (ignoring interruption)")
                activateAudioSession()
                if isPlaying && backgroundTaskID == .invalid {
                    beginBackgroundPlaybackTask(reason: "background-interruption")
                    if !isPlaybackRoutedThroughOrpheus { startPlayer(preferImmediateStart: true) }
                }
                refreshNowPlayingPlaybackState(force: true)
                return
            }
            guard isPlaying else {
                ServerLogStore.shared.debug("Audio session: Not playing, ignoring interruption")
                return
            }
            ServerLogStore.shared.info("Audio session: Real interruption, pausing playback")
            if let engine = orpheusEngine { engine.pause() } else { audioManager.pause() }
            isPlaying = false
            isPaused  = true
            endBackgroundPlaybackTask()
            refreshNowPlayingPlaybackState(force: true)

        case .ended:
            if #available(iOS 14.5, *) {
                if let reasonRaw = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
                   reasonRaw == Self.interruptionReasonAppWasSuspendedRawValue {
                    ServerLogStore.shared.debug("Audio session: App was suspended (not resuming)")
                    return
                }
            } else {
                if let suspended = userInfo[AVAudioSessionInterruptionWasSuspendedKey] as? Bool, suspended {
                    ServerLogStore.shared.debug("Audio session: App was suspended (iOS <14.5)")
                    return
                }
            }
            let shouldResume = wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false
            ServerLogStore.shared.debug("Audio session: Interruption ended (shouldResume=\(shouldResume))")
            guard let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                ServerLogStore.shared.debug("Audio session: No interruption options in notification")
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if shouldResume && options.contains(.shouldResume) {
                ServerLogStore.shared.info("Audio session: Resuming after interruption (300 ms delay)")
                if !activateAudioSession() {
                    ServerLogStore.shared.warn("Audio session reactivation failed, retrying after delay")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let self, !Task.isCancelled else { return }
                        if self.activateAudioSession() {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled else { return }
                            self.resume()
                        } else {
                            ServerLogStore.shared.error("Audio session reactivation retry failed")
                        }
                    }
                } else {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.resume()
                    }
                }
            } else {
                ServerLogStore.shared.debug("Audio session: System denied resume (shouldResume=\(shouldResume), options=\(options))")
            }

        @unknown default:
            ServerLogStore.shared.debug("Audio session: Unknown interruption type: \(type)")
        }
    }

    // Stored in the extension — static stored properties are allowed in Swift extensions.
    static let interruptionReasonAppWasSuspendedRawValue: UInt = 1

    func shouldIgnoreBackgroundInterruption(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard isPlaying,
              let reasonRaw = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt else { return false }
        if reasonRaw == Self.interruptionReasonAppWasSuspendedRawValue,
           UIApplication.shared.applicationState != .active { return true }
        #if os(visionOS)
        if let reason = AVAudioSession.InterruptionReason(rawValue: reasonRaw),
           reason == .sceneWasBackgrounded { return true }
        #endif
        return false
    }

    func handleRouteChange(_ notification: Notification) {
        guard let userInfo  = notification.userInfo,
              let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason    = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        let previousRoute = (userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
            .outputs.map { "\($0.portName)[\($0.portType.rawValue)]" }.joined(separator: ", ") ?? "none"
        ServerLogStore.shared.debug("Audio route change: \(reason), previousOutputs=\(previousRoute)")
        logAudioSessionState("route-change-\(reason)")

        switch reason {
        case .oldDeviceUnavailable:
            guard isPlaying else { return }
            ServerLogStore.shared.info("Audio device unavailable, pausing playback")
            pause()

        case .categoryChange, .newDeviceAvailable, .unknown, .override, .wakeFromSleep,
             .noSuitableRouteForCategory, .routeConfigurationChange:
            if reason == .newDeviceAvailable, orpheusEngine != nil || isPlaybackRoutedThroughOrpheus {
                let activeOutputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
                if activeOutputs.contains(.airPlay) {
                    ServerLogStore.shared.info("Orpheus: AirPlay connected mid-playback — falling back to AVPlayer")
                    orpheusFallbackReason = "AirPlay connected mid-playback"
                    pendingSeekTime = currentTime > 1 ? currentTime : nil
                    playCurrentTrack()
                    return
                }
            }
            guard isPlaying else { updateOutputFormat(); return }
            ServerLogStore.shared.debug("Route changed, reconfirming audio session")
            _ = activateAudioSession()
            updateOutputFormat()
            refreshNowPlayingPlaybackState(force: true)
            let outputVol = AVAudioSession.sharedInstance().outputVolume
            if outputVol < 0.01 {
                ServerLogStore.shared.debug("Route change: outputVolume is \(outputVol) — audio may be silent")
            }

        @unknown default:
            ServerLogStore.shared.debug("Unknown route change reason: \(reasonRaw)")
        }
    }
}
