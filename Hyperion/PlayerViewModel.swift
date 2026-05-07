import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit
import WidgetKit

@MainActor
final class PlayerViewModel: ObservableObject {

    static let shared = PlayerViewModel()

    @Published var isPlaying: Bool = false
    // isPaused is not @Published — no view observes it; it's an internal
    // sentinel distinguishing "paused" from "never started".
    private(set) var isPaused: Bool = false
    @Published var currentTrack: Track? = nil {
        didSet {
            guard let track = currentTrack, track.id != oldValue?.id else { return }
            LyricsService.shared.prefetch(for: track)
            handleTrackChangeForScrobbling(track)
        }
    }
    @Published var currentWorkGroup: WorkGroup? = nil
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    @Published var isShuffle: Bool = false
    @Published var repeatMode: Int = 0   // 0 = off, 1 = repeat-one, 2 = repeat-all
    @Published var sourceFormat: String = ""
    @Published var currentStreamURL: URL? = nil
    @Published var outputFormat: String = ""
    /// Live LMS/Lyrion metadata fetched after each track starts playing.
    /// Used for truthful signal-path diagnostics; it does not prove final output.
    @Published var lmsAudioQuality: LMSAudioQuality? = nil
    /// Deprecated compatibility flag for older debug UI. Hyperion no longer infers
    /// bit-perfect playback from extension/output-route heuristics.
    @Published var isBitPerfect: Bool = false

    /// Volume binds directly from the NowPlayingView slider; the AVPlayer is
    /// kept in sync via didSet so audio level tracks the drag in real time.
    @Published var volume: Float = 1.0 {
        didSet {
            // Guard NaN/inf — AVPlayer volume is undefined for non-finite values.
            let clamped = volume.isFinite ? max(0, min(1, volume)) : 1
            if clamped != volume { volume = clamped; return }
            player.volume = clamped * crossfadeVolume
        }
    }

    @Published var queue: [Track] = [] {
        didSet {
            recomputeWorkGroups()
            prefetchTask?.cancel()
            prefetchTask = nil
            prefetchedNextAsset = nil   // queue changed — cached asset may be wrong
            gaplessPreloadedItem = nil
            audioManager.removePreloadedItems()
            postQueueChangedNotification()
        }
    }
    @Published var currentIndex: Int = 0 {
        didSet {
            if !queueWorkGroups.isEmpty { recomputeUpcoming() }
            postQueueChangedNotification()
        }
    }

    /// All work groups covering the full queue.
    @Published private(set) var queueWorkGroups: [QueueWorkGroup] = []
    /// Subset of queueWorkGroups whose tracks have index > currentIndex.
    @Published private(set) var upcomingWorkGroups: [QueueWorkGroup] = []

    private let audioManager = AudioPlayerManager.shared
    private var player: AVPlayer { audioManager.player }
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var itemEndObservation: NSObjectProtocol?
    private var itemFailureObservation: NSObjectProtocol?
    private var itemStalledObservation: NSObjectProtocol?
    private var activePlaybackID = UUID()
    private var playbackURLCandidates: [URL] = []
    private var playbackURLIndex: Int = 0
    private var lastPlaybackErrorDescription: String?

    /// When seek() is called before the item is readyToPlay we store the
    /// target time here and apply it the moment the item becomes ready.
    private var pendingSeekTime: Double? = nil

    private var artworkLoadID: Int = 0
    private var originalQueueBeforeShuffle: [Track]?

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// True while iOS is moving the app out of the foreground. During this
    /// hand-off AVPlayer can briefly report `.paused`; that must not be
    /// interpreted as a user pause or background audio will be torn down.
    private var isHandlingBackgroundTransition = false
    private var timeControlObservation: NSKeyValueObservation?
    private var lastNowPlayingRefreshUptime: TimeInterval = 0
    private var wasPlayingBeforeInterruption = false
    private var pendingSeekWatchdogTask: Task<Void, Never>?
    private var playbackStartupWatchdogTask: Task<Void, Never>?
    private var orpheusLoadTask: Task<Void, Never>?
    private var playbackToggleDebounceTask: Task<Void, Never>?
    private var isTransitioningPlayback = false

    // MARK: - Radio mode

    /// When on, appends similar tracks automatically when the queue runs out.
    @Published var isRadioEnabled: Bool = {
        UserDefaults.standard.bool(forKey: "hyperion.radio.enabled")
    }() {
        didSet { UserDefaults.standard.set(isRadioEnabled, forKey: "hyperion.radio.enabled") }
    }

    private var radioRefreshTask: Task<Void, Never>? = nil

    // 150 ms guard: prevents double-fires from rapid taps on prev/next.
    private var lastSkipTimestamp: TimeInterval = 0

    // MARK: - Orpheus engine

    /// When true, new tracks route through OrpheusPlaybackEngine (PCM → DSP chain).
    /// Defaults to true (Orpheus is the primary engine); AVPlayer is the fallback.
    /// Persisted so the user's preference survives app restarts.
    @Published var useOrpheusEngine: Bool = {
        // First-launch default is true; respect any explicit user toggle saved in UserDefaults.
        let ud = UserDefaults.standard
        return ud.object(forKey: "hyperion.orpheus.enabled") != nil
            ? ud.bool(forKey: "hyperion.orpheus.enabled")
            : true
    }() {
        didSet { UserDefaults.standard.set(useOrpheusEngine, forKey: "hyperion.orpheus.enabled") }
    }
    /// True only when audio is confirmed to be flowing through the Orpheus DSP chain.
    /// Set to true after the first PCM buffer plays (not just after load).
    @Published private(set) var isPlaybackRoutedThroughOrpheus: Bool = false
    /// Convenience alias — true iff Orpheus is the active playback engine right now.
    var isOrpheusActive: Bool { isPlaybackRoutedThroughOrpheus }
    private var orpheusEngine: OrpheusPlaybackEngine?

    // MARK: - Orpheus diagnostics (mirrors engine state for debug UI)

    /// True after the first audio buffer has actually played through the DSP chain.
    @Published private(set) var orpheusDidStartAudiblePlayback: Bool = false
    /// Human-readable source codec / sample-rate / channel description from AVAssetTrack.
    @Published private(set) var orpheusDecodedFormat: String = ""
    /// True when the loaded asset has a known finite duration.
    @Published private(set) var orpheusDurationKnown: Bool = false
    /// True when seeking is safe (asset is finite and seekable via AVAssetReader).
    @Published private(set) var orpheusCanSeek: Bool = false
    /// Internal buffer-loop mode (fileLike vs streaming).
    @Published private(set) var orpheusPlaybackMode: OrpheusPlaybackMode = .fileLike
    /// URL classification determined during asset load (fileLike / streamLike / unknown).
    @Published private(set) var orpheusStreamKind: OrpheusStreamKind = .unknown
    /// Human-readable reason the last Orpheus→AVPlayer fallback was triggered, if any.
    @Published private(set) var orpheusFallbackReason: String? = nil

    /// Prefetched AVURLAsset for the next track. Built as soon as the current
    /// track starts playing so the asset headers are already loaded when the
    /// user skips forward. Discarded whenever the queue changes.
    private var prefetchedNextAsset: (trackID: Int, asset: AVURLAsset)? = nil
    private var prefetchTask: Task<Void, Never>? = nil
    private var lmsAudioQualityTask: Task<Void, Never>? = nil

    // MARK: - Gapless playback (AVPlayer path only)

    /// Pre-inserted AVPlayerItem in the AVQueuePlayer for the next track.
    /// When non-nil the player already has this item queued and will advance
    /// to it without a silence gap when the current item ends.
    private var gaplessPreloadedItem: (trackID: Int, item: AVPlayerItem, url: URL)? = nil

    // MARK: - Crossfade (AVPlayer path only)

    /// Duration in seconds of the fade-out/fade-in at track boundaries.
    /// 0 = off. Persisted in UserDefaults.
    @Published var crossfadeDuration: Double = {
        UserDefaults.standard.double(forKey: "hyperion.crossfade.duration")
    }() {
        didSet { UserDefaults.standard.set(crossfadeDuration, forKey: "hyperion.crossfade.duration") }
    }
    /// Multiplied with `volume` to produce the actual AVPlayer volume during
    /// crossfade ramps. 1.0 at rest, ramps 1→0 on fade-out, 0→1 on fade-in.
    private var crossfadeVolume: Float = 1.0
    private var crossfadeTask: Task<Void, Never>? = nil
    private var isCrossfadingOut: Bool = false

    /// Prevents fetching radio tracks more than once per track when ≤30 s remain.
    private var radioEarlyFetchTriggered: Bool = false

    // MARK: - Last.fm scrobbling state
    private var scrobbleTrackID: Int?
    private var scrobbleStartTimestamp: TimeInterval = 0
    private var scrobbleThreshold: Double = 0   // seconds: min(duration/2, 240)
    private var hasScrobbled: Bool = false

    // MARK: - "Resume where you left off" state persistence

    /// Schedules a debounced save of the current playback snapshot.
    // MARK: - Scrobbling helpers

    private func handleTrackChangeForScrobbling(_ track: Track) {
        scrobbleTrackID = track.id
        scrobbleStartTimestamp = Date().timeIntervalSince1970
        hasScrobbled = false
        let dur = track.duration ?? 0
        scrobbleThreshold = dur > 30 ? min(dur / 2, 240) : .infinity

        let lfm = LastFmAuthManager.shared
        guard lfm.isSignedIn else { return }
        lfm.updateNowPlaying(
            track:    track.title ?? "",
            artist:   track.trackartist ?? track.albumartist ?? "",
            album:    track.album,
            duration: track.duration
        )
    }

    private func checkScrobbleThreshold(_ time: Double) {
        guard !hasScrobbled,
              let tid = scrobbleTrackID,
              let track = currentTrack, track.id == tid,
              scrobbleThreshold.isFinite,
              time >= scrobbleThreshold else { return }
        hasScrobbled = true
        LastFmAuthManager.shared.scrobble(
            track:     track.title ?? "",
            artist:    track.trackartist ?? track.albumartist ?? "",
            album:     track.album,
            timestamp: scrobbleStartTimestamp,
            duration:  track.duration
        )
    }

    /// Called from the periodic time observer (every 0.5 s) with a 2-second
    /// debounce so disk I/O is bounded to ≤ 1 write per 2 s while scrubbing.
    private func schedulePlaybackStateSave() {
        guard !queue.isEmpty else { return }
        PlaybackStateStore.shared.scheduleSave(
            queue:                       queue,
            currentIndex:                currentIndex,
            currentTime:                 currentTime,
            isShuffle:                   isShuffle,
            repeatMode:                  repeatMode,
            originalQueueBeforeShuffle:  originalQueueBeforeShuffle,
            currentWorkGroupID:          currentWorkGroup.map { $0.id }
        )
    }

    /// Saves immediately — used on termination / background where there is no
    /// time for the debounce timer to fire.
    private func savePlaybackStateNow() {
        guard !queue.isEmpty else { return }
        PlaybackStateStore.shared.saveNow(
            queue:                       queue,
            currentIndex:                currentIndex,
            currentTime:                 currentTime,
            isShuffle:                   isShuffle,
            repeatMode:                  repeatMode,
            originalQueueBeforeShuffle:  originalQueueBeforeShuffle,
            currentWorkGroupID:          currentWorkGroup.map { $0.id }
        )
    }

    // MARK: - Restore

    /// Restores a previously saved playback session without auto-playing.
    /// Returns true if a snapshot was found and applied; false if there was
    /// nothing to restore (so the caller can decide whether to show the banner).
    @discardableResult
    func restoreLastSession() -> Bool {
        guard let snap = PlaybackStateStore.shared.loadSnapshot(),
              !snap.queue.isEmpty else { return false }

        // Restore queue state without triggering a new playback.
        originalQueueBeforeShuffle = snap.originalQueueBeforeShuffle
        isShuffle                  = snap.isShuffle
        repeatMode                 = snap.repeatMode

        // Setting queue triggers recomputeWorkGroups via didSet — that's fine,
        // it gives us the correct queueWorkGroups before we set currentIndex.
        queue        = snap.queue
        currentIndex = max(0, min(snap.currentIndex, snap.queue.count - 1))

        // Seed the track + progress state so the mini-player and Now Playing
        // view display immediately without waiting for a network load.
        currentTrack = snap.queue.indices.contains(currentIndex) ? snap.queue[currentIndex] : snap.queue.first
        currentTime  = snap.currentTime
        duration     = currentTrack?.duration ?? 0
        progress     = duration > 0 ? min(1, currentTime / duration) : 0

        // Seed the pending seek so if the user hits Play we land at the right
        // position once the stream becomes ready.
        pendingSeekTime = snap.currentTime > 1 ? snap.currentTime : nil

        syncCurrentWorkGroup()
        updateNowPlayingInfo(track: currentTrack)
        refreshNowPlayingPlaybackState(force: true)

        return true
    }

    // PASS 6 — the player no longer owns its own artwork cache. Lock-screen
    // and Now Playing artwork share the unified ArtworkCache (see ContentView)
    // so we don't decode and store the same album art twice. Memory warnings
    // are handled directly inside ArtworkCache, so PlayerViewModel no longer
    // needs its own observer.

    private init() {
        // Touch the shared AudioPlayerManager immediately. Its initializer
        // configures and activates AVAudioSession before creating AVPlayer.
        _ = audioManager
        setupAudioSession()

        setupRemoteControls()
        setupAudioObservers()
        setupAppLifecycleObservers()
        logAudioSessionState("player-view-model-init")
    }

    deinit {
        // `deinit` for a global-actor isolated class runs from a nonisolated
        // context under newer Swift toolchains, so do only nonisolated cleanup
        // here and hop back to the main actor for diagnostics.
        Task { @MainActor in
            ServerLogStore.shared.error("PlayerViewModel deinit — audio manager lifetime was broken")
        }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let token = itemEndObservation { NotificationCenter.default.removeObserver(token) }
        if let token = itemFailureObservation { NotificationCenter.default.removeObserver(token) }
        if let token = itemStalledObservation { NotificationCenter.default.removeObserver(token) }
        prefetchTask?.cancel()
        lmsAudioQualityTask?.cancel()
    }

    // MARK: - CarPlay notification

    private func postQueueChangedNotification() {
        NotificationCenter.default.post(name: .hyperionQueueChanged, object: nil)
    }

    // MARK: - Queue work-group bookkeeping

    private func recomputeWorkGroups() {
        var groups: [QueueWorkGroup]  = []
        var currentKey: String?       = nil
        var currentTitle: String?     = nil
        var currentComposer: String?  = nil
        var currentItems: [QueueWorkGroup.QueueTrackItem] = []

        func keyFor(_ track: Track) -> (key: String, title: String) {
            if let work = track.work, !work.isEmpty {
                return ("w:\(work)|c:\(track.composer ?? "")", work)
            }
            return ("a:\(track.album ?? "")", track.album ?? "Unknown")
        }

        func flush() {
            guard !currentItems.isEmpty else { return }
            groups.append(QueueWorkGroup(
                id:        currentItems[0].index,
                workTitle: currentTitle ?? "Unknown Work",
                composer:  currentComposer,
                tracks:    currentItems
            ))
            currentItems = []
        }

        for (index, track) in queue.enumerated() {
            let (key, title) = keyFor(track)
            if key != currentKey {
                flush()
                currentKey      = key
                currentTitle    = title
                currentComposer = track.composer
            }
            currentItems.append(.init(index: index, track: track))
        }
        flush()
        queueWorkGroups = groups
        recomputeUpcoming()
    }

    private func recomputeUpcoming() {
        upcomingWorkGroups = queueWorkGroups.compactMap { group in
            let upcoming = group.tracks.filter { $0.index > currentIndex }
            guard !upcoming.isEmpty else { return nil }
            return QueueWorkGroup(
                id:        upcoming[0].index,
                workTitle: group.workTitle,
                composer:  group.composer,
                tracks:    upcoming
            )
        }
    }

    // MARK: - Audio session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Background music playback requires the playback category. Keep
            // this configuration simple and idempotent; activation happens
            // before AVPlayer creation and again immediately before playback.
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
            // Reconfirm the category before activation. Route changes and
            // interruptions can alter the session state; this idempotent call
            // ensures we're in the right category mode for playback.
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

    private func deactivateAudioSession(force: Bool = false) {
        guard force || !isPlaying else { return }
        endBackgroundPlaybackTask()
        do {
            // Only deactivate if we're force-stopping (clearQueue) or truly stopped.
            // Keep the session active while paused so remote controls and background
            // resume operations still work properly.
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            ServerLogStore.shared.debug("Audio session deactivated")
        } catch {
            ServerLogStore.shared.error("Audio session deactivation failed: \(error.localizedDescription)")
        }
    }

    private func logAudioSessionState(_ label: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        ServerLogStore.shared.debug(
            "Audio session state [\(label)]: category=\(session.category.rawValue), mode=\(session.mode.rawValue), sampleRate=\(Int(session.sampleRate)), outputs=\(outputs.isEmpty ? "none" : outputs)"
        )
    }

    private func describeTimeControlStatus(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waitingToPlayAtSpecifiedRate"
        case .playing: return "playing"
        @unknown default: return "unknown"
        }
    }

    private func describeItemStatus(_ item: AVPlayerItem?) -> String {
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

    private func setupAppLifecycleObservers() {
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

    private func handleWillResignActive() {
        guard isPlaying else { return }

        // The app is leaving the foreground. Start the audio hand-off before
        // UIApplication.didEnterBackground arrives so a transient AVPlayer
        // `.paused` state cannot be mistaken for a user pause.
        isHandlingBackgroundTransition = true
        savePlaybackStateNow()
        beginBackgroundPlaybackTask(reason: "will-resign-active")

        if activateAudioSession() && !isPlaybackRoutedThroughOrpheus {
            startPlayer(preferImmediateStart: true)
        }
        refreshNowPlayingPlaybackState(force: true)
    }

    private func handleDidEnterBackground() {
        let orpheusIsAudiblyPlaying = isPlaybackRoutedThroughOrpheus && (orpheusEngine?.isPlaying == true)
        let playerIsAudiblyPlaying  = player.rate > 0 || player.timeControlStatus == .playing || orpheusIsAudiblyPlaying

        guard isPlaying || playerIsAudiblyPlaying else {
            // Save position even when paused so resuming after a cold relaunch
            // lands at the right track/position. Do not deactivate the audio
            // session from a background lifecycle callback: a just-started
            // stream may briefly report paused while iOS transfers playback to
            // the background audio daemon.
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

        // Keep the process alive while the audio session is reconfirmed and
        // AVPlayer is nudged into playback. The task is ended as soon as the
        // player reports .playing; it is not used to keep audio alive long-term.
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
            // AVAudioEngine keeps audio running in background automatically once
            // the session is active in .playback category. No AVPlayer nudge needed.
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

    private func handleWillEnterForeground() {
        isHandlingBackgroundTransition = false
        // When returning to foreground, re-confirm audio session is still active.
        // iOS may have deactivated it during background transition on some devices.
        if isPlaying {
            activateAudioSession()
        }
        endBackgroundPlaybackTask()
        refreshNowPlayingPlaybackState(force: true)
    }

    private func handleWillTerminate() {
        savePlaybackStateNow()
        refreshNowPlayingPlaybackState(force: true)
        endBackgroundPlaybackTask()
    }

    private func beginBackgroundPlaybackTask(reason: String) {
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
                    // Never pause from a background-task expiration handler.
                    // Once AVAudioSession is active in .playback and the app has
                    // UIBackgroundModes=audio, iOS owns the long-running audio
                    // lifetime; this task is only a short startup/transition guard.
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

    private func endBackgroundPlaybackTask() {
        guard backgroundTaskID != .invalid else { return }
        let taskID = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
    }

    // MARK: - Audio observers

    private func setupAudioObservers() {
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

    private func handleInterruption(_ notification: Notification) {
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

            // Special case: on some iOS versions, backgrounding surfaces as an
            // interruption. For an app with audio background mode, we should NOT
            // pause playback in this case. Detect and handle specially.
            if shouldIgnoreBackgroundInterruption(userInfo) {
                ServerLogStore.shared.debug("Audio session: Background transition (ignoring interruption)")
                // Re-confirm audio session is active for background playback
                activateAudioSession()
                // If we were playing, ensure playback continues with a background task.
                // AVAudioEngine (Orpheus) manages its own background continuity via the
                // audio session; only nudge AVPlayer when Orpheus is not active.
                if isPlaying && backgroundTaskID == .invalid {
                    beginBackgroundPlaybackTask(reason: "background-interruption")
                    if !isPlaybackRoutedThroughOrpheus {
                        startPlayer(preferImmediateStart: true)
                    }
                }
                refreshNowPlayingPlaybackState(force: true)
                return
            }

            // Real interruption (phone call, Siri, alarm, etc).
            // Only pause if we're actually playing.
            guard isPlaying else {
                ServerLogStore.shared.debug("Audio session: Not playing, ignoring interruption")
                return
            }

            // Pause playback. We'll only resume if the system grants permission.
            ServerLogStore.shared.info("Audio session: Real interruption, pausing playback")
            if let engine = orpheusEngine {
                engine.pause()
            } else {
                audioManager.pause()
            }
            isPlaying = false
            isPaused  = true
            endBackgroundPlaybackTask()
            refreshNowPlayingPlaybackState(force: true)

        case .ended:
            // Interruption has ended. Check if we're allowed to resume.

            // First, check if this was actually a background transition
            // (appWasSuspended), not a real interruption.
            if #available(iOS 14.5, *) {
                if let reasonRaw = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
                   reasonRaw == Self.interruptionReasonAppWasSuspendedRawValue {
                    ServerLogStore.shared.debug("Audio session: App was suspended (not resuming)")
                    return
                }
            } else {
                // Fallback for iOS < 14.5
                if let suspended = userInfo[AVAudioSessionInterruptionWasSuspendedKey] as? Bool,
                   suspended {
                    ServerLogStore.shared.debug("Audio session: App was suspended (iOS <14.5)")
                    return
                }
            }

            let shouldResume = wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false

            ServerLogStore.shared.debug("Audio session: Interruption ended (shouldResume=\(shouldResume))")

            // Check if the system grants permission to resume
            guard let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                ServerLogStore.shared.debug("Audio session: No interruption options in notification")
                return
            }

            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)

            if shouldResume && options.contains(.shouldResume) {
                // System grants permission. Reactivate audio session and resume.
                // A 300 ms delay gives iOS time to fully release the call audio
                // session before we try to reclaim it for music playback.
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

    private static let interruptionReasonAppWasSuspendedRawValue: UInt = 1

    private func shouldIgnoreBackgroundInterruption(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard isPlaying,
              let reasonRaw = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt else {
            return false
        }

        // Only treat as a background transition if iOS explicitly flagged it as
        // app-suspension AND the app is genuinely backgrounded. Without the
        // applicationState check, a phone call arriving with the screen locked
        // could be misclassified as a background transition and skip pausing.
        if reasonRaw == Self.interruptionReasonAppWasSuspendedRawValue,
           UIApplication.shared.applicationState != .active {
            return true
        }

        #if os(visionOS)
        if let reason = AVAudioSession.InterruptionReason(rawValue: reasonRaw),
           reason == .sceneWasBackgrounded {
            return true
        }
        #endif

        return false
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo  = notification.userInfo,
              let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason    = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        let previousRoute = (userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
            .outputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ") ?? "none"
        ServerLogStore.shared.debug("Audio route change: \(reason), previousOutputs=\(previousRoute)")
        logAudioSessionState("route-change-\(reason)")

        switch reason {
        case .oldDeviceUnavailable:
            // Audio route changed (e.g., headphones unplugged). Pause playback
            // unless configured to continue on speaker. Always pause on device loss.
            guard isPlaying else { return }
            ServerLogStore.shared.info("Audio device unavailable, pausing playback")
            pause()

        case .categoryChange, .newDeviceAvailable, .unknown, .override, .wakeFromSleep, .noSuitableRouteForCategory, .routeConfigurationChange:
            // If AirPlay just became active while Orpheus is playing, restart via AVPlayer.
            // AVAudioEngine cannot route to AirPlay; continuing would produce silence with
            // no error reported and the UI showing Orpheus as active.
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
            // Route changed but not necessarily a device loss. If we're playing,
            // ensure the audio session is still active and reconfirm it's ready.
            guard isPlaying else {
                // Update output format even if not playing, for display purposes
                updateOutputFormat()
                return
            }
            ServerLogStore.shared.debug("Route changed, reconfirming audio session")
            _ = activateAudioSession()
            updateOutputFormat()
            refreshNowPlayingPlaybackState(force: true)
            // Detect silent-but-playing state: device volume at 0 means audio is
            // flowing but inaudible. Log for diagnostics; do not pause automatically
            // (the user may intend to unmute).
            let outputVol = AVAudioSession.sharedInstance().outputVolume
            if outputVol < 0.01 {
                ServerLogStore.shared.debug("Route change: outputVolume is \(outputVol) — audio may be silent")
            }

        @unknown default:
            ServerLogStore.shared.debug("Unknown route change reason: \(reasonRaw)")
        }
    }

    // MARK: - Lock screen / remote controls

    private func setupRemoteControls() {
        // Begin receiving remote control events. This allows the app to respond
        // to lock-screen and CarPlay controls even when backgrounded.
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let cc = MPRemoteCommandCenter.shared()
        // Clean up any old handlers to ensure we don't register duplicates
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)

        MPNowPlayingInfoCenter.default().playbackState = .stopped

        // Enable all remote controls. MediaPlayer may invoke handlers off the
        // main thread, so each handler hops back to MainActor before touching
        // SwiftUI/AVPlayer-backed state.
        cc.playCommand.isEnabled            = true
        cc.pauseCommand.isEnabled           = true
        cc.togglePlayPauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled       = true
        cc.previousTrackCommand.isEnabled   = true
        cc.changePlaybackPositionCommand.isEnabled = true

        // Register handlers for each remote control command. Each handler
        // will be called from the lock screen or Control Center, even when
        // the app is backgrounded.
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
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = e.positionTime
            Task { @MainActor [weak self] in
                guard let self else { return }
                ServerLogStore.shared.debug("Remote: Seek to \(String(format: "%.1f", position))s")
                self.seek(to: position)
            }
            return .success
        }

        // Disable skip commands (we use next/previous instead)
        cc.skipForwardCommand.isEnabled  = false
        cc.skipBackwardCommand.isEnabled = false

        ServerLogStore.shared.debug("Remote controls registered")
    }

    // MARK: - Public playback API

    func playWork(_ workGroup: WorkGroup) {
        playWork(workGroup, startingAt: 0)
    }

    func playWork(_ workGroup: WorkGroup, startingAt index: Int) {
        guard !workGroup.tracks.isEmpty else { return }
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
        originalQueueBeforeShuffle = nil
        isShuffle        = false
        currentWorkGroup = workGroups.first
        queue            = tracks
        currentIndex     = 0
        playCurrentTrack()
    }

    func playSingleTrack(_ track: Track) {
        originalQueueBeforeShuffle = nil
        isShuffle        = false
        currentWorkGroup = nil
        queue            = [track]
        currentIndex     = 0
        playCurrentTrack()
    }

    func playTracks(_ tracks: [Track], startingAt index: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
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
        // Append all tracks in a single mutation so recomputeWorkGroups() runs
        // once (via queue.didSet) rather than once per work group.
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

    /// Inserts tracks immediately after the current position (Play Next).
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
        // Sync the current index and then start playback of that track.
        currentIndex = index
        syncCurrentWorkGroup()
        playCurrentTrack()
    }

    func pause() {
        ServerLogStore.shared.debug("Pause called")
        // Route to whichever engine is active. Use orpheusEngine != nil rather than
        // isPlaybackRoutedThroughOrpheus so we don't miss the brief window between
        // engine.play() and the first-audio routing confirmation.
        if let engine = orpheusEngine {
            engine.pause()
        } else {
            audioManager.pause()
        }
        isPlaying = false
        isPaused  = true
        isTransitioningPlayback = false
        // End background task but keep audio session active for resumed playback
        endBackgroundPlaybackTask()
        // Update lock screen immediately
        MPNowPlayingInfoCenter.default().playbackState = .paused
        refreshNowPlayingPlaybackState(force: true)
        NowPlayingWidgetStore.shared.update(track: currentTrack, isPlaying: false)
    }

    func resume() {
        guard currentTrack != nil || !queue.isEmpty else {
            ServerLogStore.shared.debug("Resume: No track or queue available")
            return
        }

        // Orpheus fast path — engine exists and holds the loaded asset.
        // Check orpheusEngine != nil (not just isPlaybackRoutedThroughOrpheus) so
        // resume works in the window before first-audio confirmation.
        if let engine = orpheusEngine {
            guard activateAudioSession() else { return }
            if isPaused {
                // Lightweight resume: playerNode.play() without stop/reset.
                // This preserves scheduled buffers and the node's elapsed-time counter,
                // avoiding audio dropout and time-position jumps on every resume.
                engine.resume()
            } else {
                // Not paused (e.g., initial play before first-audio confirmation).
                engine.play()
            }
            isPlaying = true
            isPaused  = false
            MPNowPlayingInfoCenter.default().playbackState = .playing
            refreshNowPlayingPlaybackState(force: true)
            return
        }

        // If no player item exists but queue is valid, we need to start playback
        // from scratch (e.g., app was force-quit or tracks were cleared).
        if player.currentItem == nil, queue.indices.contains(currentIndex) {
            ServerLogStore.shared.debug("Resume: No player item, starting from track \(currentIndex)")
            playCurrentTrack()
            return
        }

        // Reactivate the audio session. This must succeed or we can't play.
        guard activateAudioSession() else {
            ServerLogStore.shared.error("Resume: Failed to activate audio session")
            isPlaying = false
            return
        }

        let isInBackground = UIApplication.shared.applicationState != .active
        ServerLogStore.shared.info("Resume: starting from \(isInBackground ? "background" : "foreground")")

        // If resuming in background, ensure we have a background task running.
        // This keeps the process alive while playback starts. The task will be
        // released when timeControlStatus reaches .playing.
        if isInBackground && backgroundTaskID == .invalid {
            beginBackgroundPlaybackTask(reason: "resume-background")
        }

        // Force immediate start if in background so playback begins before
        // iOS makes its suspend decision.
        startPlayer(preferImmediateStart: isInBackground)
        isPlaying = true
        isPaused  = false
        refreshNowPlayingPlaybackState(force: true)
        // Update the lock-screen immediately.
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    func togglePlayPause() {
        guard !isTransitioningPlayback else { return }
        isTransitioningPlayback = true
        if isPlaying { pause() } else { resume() }
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
        guard !queue.isEmpty else { return }
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            playCurrentTrack()
        } else if repeatMode == 2 {
            currentIndex = 0
            playCurrentTrack()
        }
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
    }

    func seek(to time: Double) {
        let clamped = duration > 0 ? max(0, min(duration, time)) : max(0, time)

        if isPlaybackRoutedThroughOrpheus {
            // Engine guards against unseekable streams internally; safe to call.
            orpheusEngine?.seek(to: clamped)
            currentTime = clamped
            progress    = duration > 0 ? clamped / duration : 0
            refreshNowPlayingPlaybackState(force: true)
            return
        }

        // Clamp to [0, duration] when duration is known; when duration == 0 (not
        // yet loaded) just clamp to positive — the pending-seek path will apply it
        // once the item becomes readyToPlay.

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
        guard queue.indices.contains(currentIndex) else {
            currentIndex = 0
            return
        }

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

    private func filteredOriginalQueuePreservingCounts() -> [Track]? {
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

    // MARK: - Queue management

    func clearQueue() {
        orpheusEngine?.stop()
        orpheusEngine = nil
        isPlaybackRoutedThroughOrpheus = false
        orpheusDidStartAudiblePlayback = false
        orpheusDecodedFormat  = ""
        orpheusDurationKnown  = false
        orpheusCanSeek        = false
        orpheusPlaybackMode   = .fileLike
        orpheusStreamKind     = .unknown
        orpheusFallbackReason = nil

        // Cancel all pending tasks and observers to prevent stale callbacks.
        pendingSeekWatchdogTask?.cancel()
        pendingSeekWatchdogTask = nil
        playbackStartupWatchdogTask?.cancel()
        playbackStartupWatchdogTask = nil
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

        // Invalidate all KVO observations first.
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil

        // Stop playback and clean up the player.
        audioManager.pause()
        audioManager.replaceCurrentItem(with: nil)
        playerItem = nil
        removeTimeObserver()
        removeItemNotificationObservers()

        // Clean up playback state.
        pendingSeekTime       = nil
        playbackURLCandidates = []
        playbackURLIndex      = 0
        lastPlaybackErrorDescription = nil
        activePlaybackID = UUID()

        // Clear Now Playing and background task.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        endBackgroundPlaybackTask()

        // Sync state and deactivate audio.
        isPlaying = false
        isPaused  = false
        deactivateAudioSession(force: true)

        // Clear the persisted session so a cold relaunch starts fresh.
        PlaybackStateStore.shared.clear()

        // Clear the queue and UI state.
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
            if isPlaying {
                playCurrentTrack()
            } else if isPaused {
                playCurrentTrack(autoPlay: false)
            }
        }

        if originalQueueBeforeShuffle != nil {
            originalQueueBeforeShuffle = filteredOriginalQueuePreservingCounts()
        }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let sortedSource = source.sorted().filter { queue.indices.contains($0) }
        guard !sortedSource.isEmpty else { return }

        let oldCurrentIndex = currentIndex
        let sourceSet = Set(sortedSource)
        let movingTracks = sortedSource.map { queue[$0] }
        let currentWasMoved = sourceSet.contains(oldCurrentIndex)
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

        // Re-queue the new next track for gapless playback after the reorder.
        prefetchNextTrackAsset()
    }

    // MARK: - Artwork (delegates to ArtworkCache)
    //
    // PASS 6 — kept as a public API for artwork view / lock-screen callers,
    // but now backed by the single ArtworkCache. The `targetPoints`
    // parameter lets us decode at the right size: lock-screen ~600pt,
    // blurred Now Playing background ~600pt (it gets blurred to oblivion
    // anyway, so a small image is plenty).

    func loadImage(from url: URL, targetPoints: CGFloat = 600) async -> UIImage? {
        // We're @MainActor — reading displayScale here is safe.
        // UITraitCollection.current.displayScale is the modern API;
        // UIScreen.main.scale is a belt-and-suspenders fallback only.
        let scale: CGFloat
        if #available(iOS 17.0, *) {
            scale = UITraitCollection.current.displayScale > 0
                ? UITraitCollection.current.displayScale
                : 2.0  // safe default; all modern iPhones are 2x or 3x
        } else {
            scale = UITraitCollection.current.displayScale > 0
                ? UITraitCollection.current.displayScale
                : UIScreen.main.scale
        }
        return await ArtworkCache.shared.loadImage(
            url: url,
            targetPoints: targetPoints,
            scale: scale
        )
    }

    // MARK: - Private playback

    private func playCurrentTrack(autoPlay: Bool = true) {
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

    private func playCurrentTrackOrpheus(autoPlay: Bool = true) {
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
            if self.crossfadeDuration > 0 && remaining > 0
               && remaining <= self.crossfadeDuration && !self.isCrossfadingOut {
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
                self.prefetchNextTrackAsset()
            }
        }
        engine.onNearEnd = { [weak self] in
            guard let self, playbackID == self.activePlaybackID else { return }
            self.prefetchNextTrackAsset()
            if self.crossfadeDuration > 0, !self.isCrossfadingOut {
                self.startCrossfadeOut()
            }
        }

        let headers = LyrionAPI.shared.httpHeaders(
            accept: "audio/flac,audio/mpeg,audio/mp4,audio/aac,audio/wav,audio/*,*/*"
        )

        orpheusLoadTask?.cancel()
        orpheusLoadTask = Task { @MainActor [weak self] in
            guard let self, self.orpheusEngine === engine, playbackID == self.activePlaybackID else { return }
            do {
                try await engine.load(url: candidates[0], headers: headers, startTime: startTime)
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

    private func updateSourceFormat(from track: Track) {
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
    private func updateOutputFormat() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute

        // Determine output device type
        let outputPortTypes = route.outputs.map(\.portType)
        var deviceName = "Unknown"
        var isLossless = false

        if outputPortTypes.contains(.headphones) {
            deviceName = "Headphones"
            isLossless = true
        } else if outputPortTypes.contains(.builtInSpeaker) {
            deviceName = "Speaker"
            isLossless = true
        } else if outputPortTypes.contains(.airPlay) {
            deviceName = "AirPlay"
            isLossless = false
        } else if outputPortTypes.contains(.carAudio) {
            deviceName = "CarPlay"
            isLossless = false
        } else if outputPortTypes.contains(.bluetoothA2DP) || outputPortTypes.contains(.bluetoothLE) {
            deviceName = "Bluetooth"
            isLossless = false
        } else if !outputPortTypes.isEmpty {
            deviceName = outputPortTypes.first?.rawValue ?? "Unknown"
            isLossless = true
        }

        // Get channel count and sample rate from the session
        let channelCount = session.outputNumberOfChannels
        let sampleRate = session.sampleRate > 0 ? Int(session.sampleRate) : 48000

        // Format: "Device (sample rate Hz, N channels)"
        outputFormat = "\(deviceName) (\(sampleRate) Hz, \(channelCount)ch)"

        // Do not mark bit-perfect from route/source heuristics. The signal-path
        // model requires final stream/output and processing facts that AVAudioSession
        // does not expose here.
        _ = isLossless
        isBitPerfect = false

        ServerLogStore.shared.debug("Audio output: \(outputFormat) (bit-perfect not inferred from route)")
    }

    private func beginPlayback(
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
                        )
                    }

                    if autoPlay {
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
                if !self.isPlaybackRoutedThroughOrpheus && self.crossfadeDuration > 0
                   && remaining > 0 && remaining <= self.crossfadeDuration && !self.isCrossfadingOut {
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
    private func fetchLMSAudioQuality(for track: Track, playbackID: UUID) {
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
                    statusResult = try await LyrionAPI.shared.request(params: ["status", "-", 1, "tags:\(tags)"])
                    statusTrack = Self.firstLoopEntry(in: statusResult, keys: ["playlist_loop"]) ?? [:]
                    if let statusID = Self.intValue(statusTrack["id"] ?? statusTrack["track_id"]) {
                        statusMatchedCurrentTrack = statusID == track.id
                    }
                } catch {
                    ServerLogStore.shared.debug("LMS status diagnostics unavailable for signal path: \(error.localizedDescription)")
                }

                let statusCanFill = statusMatchedCurrentTrack == true
                let type = Self.firstString([songInfo["type"], statusCanFill ? statusTrack["type"] : nil, track.audioType])?.lowercased() ?? ""
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
                    rawTrackFields: Self.rawFieldMap(songInfo),
                    rawStatusFields: rawStatusFields,
                    fieldsUsed: fieldsUsed,
                    missingFields: missing,
                    statusMatchedCurrentTrack: statusMatchedCurrentTrack
                )

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

    private func retryNextPlaybackURL(track: Track, autoPlay: Bool, playbackID: UUID) {
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


    private func installPlaybackStartupWatchdog(track: Track, autoPlay: Bool, playbackID: UUID) {
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

    private func clearPlaybackStartupWatchdog() {
        playbackStartupWatchdogTask?.cancel()
        playbackStartupWatchdogTask = nil
    }

    private func startPlayer(preferImmediateStart: Bool = false) {
        // Always use playImmediately — on a local LMS server there is no
        // network buffering delay to protect against, and this eliminates the
        // "waiting to play at specified rate" pause that adds ~300–500 ms.
        player.playImmediately(atRate: 1.0)
    }

    /// Prefetch the next track's AVURLAsset so its HTTP headers are already
    /// resolved when the user skips. Also pre-inserts an AVPlayerItem into the
    /// AVQueuePlayer so it can advance gaplessly when the current item ends.
    private func prefetchNextTrackAsset() {
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
        prefetchTask = Task.detached(priority: .background) {
            _ = try? await asset.load(.duration)
        }
        prefetchedNextAsset = (trackID: nextTrack.id, asset: asset)

        // Pre-insert a player item for gapless advance (AVPlayer path only).
        // Orpheus manages its own buffer pipeline and cannot share AVPlayerItems.
        if !isPlaybackRoutedThroughOrpheus {
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

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus, playbackID: UUID) {
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

    private func syncCurrentWorkGroup() {
        guard let match = queueWorkGroups.first(where: { group in
            group.tracks.contains(where: { $0.index == currentIndex })
        }) else {
            currentWorkGroup = nil
            return
        }

        currentWorkGroup = WorkGroup(
            id:        match.id,
            workTitle: match.workTitle,
            composer:  match.composer,
            tracks:    match.tracks.map(\.track),
            coverid:   match.tracks.first?.track.coverid
        )
    }

    private func trackDidFinish() {
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
                if !isPlaybackRoutedThroughOrpheus,
                   let g = gaplessPreloadedItem,
                   queue.indices.contains(nextIdx),
                   g.trackID == queue[nextIdx].id {
                    if g.item.status == .failed {
                        // Preloaded item failed before use — clear it and start fresh.
                        ServerLogStore.shared.warn("Gapless: preloaded item failed — falling back to nextTrack()")
                        gaplessPreloadedItem = nil
                        audioManager.removePreloadedItems()
                        nextTrack()
                    } else {
                        performGaplessAdvance(nextIndex: nextIdx)
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
    private func performGaplessAdvance(nextIndex: Int) {
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
                if self.crossfadeDuration > 0 && remaining > 0
                   && remaining <= self.crossfadeDuration && !self.isCrossfadingOut {
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
    private func startCrossfadeOut() {
        guard crossfadeDuration > 0 else { return }
        isCrossfadingOut = true
        crossfadeTask?.cancel()
        let steps    = max(1, Int(crossfadeDuration / 0.016))
        let startVol = crossfadeVolume
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for i in 0..<steps {
                guard !Task.isCancelled else { return }
                // Equal-power: cos(t·π/2) from startVol → 0
                let t   = Float(i + 1) / Float(steps)
                let vol = startVol * cos(t * .pi / 2)
                self.crossfadeVolume       = max(0, vol)
                self.player.volume         = max(0, min(1, self.volume)) * self.crossfadeVolume
                self.orpheusEngine?.volume = self.crossfadeVolume
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.crossfadeVolume       = 0
            self.player.volume         = 0
            self.orpheusEngine?.volume = 0
        }
    }

    /// Ramp `crossfadeVolume` from 0 up to 1 over `crossfadeDuration`.
    /// Uses an equal-power (sine) curve — the complementary half of the fade-out
    /// curve — so the combined loudness of both tracks stays flat at every point.
    /// Resets immediately to 1 when crossfade is off.
    private func startCrossfadeIn() {
        crossfadeTask?.cancel()
        isCrossfadingOut = false
        guard crossfadeDuration > 0 else {
            crossfadeVolume        = 1
            player.volume          = max(0, min(1, volume))
            orpheusEngine?.volume  = 1
            return
        }
        crossfadeVolume        = 0
        player.volume          = 0
        orpheusEngine?.volume  = 0
        let steps = max(1, Int(crossfadeDuration / 0.016))
        crossfadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for i in 0..<steps {
                guard !Task.isCancelled else { return }
                // Equal-power: sin(t·π/2) from 0 → 1
                let t   = Float(i + 1) / Float(steps)
                let vol = sin(t * .pi / 2)
                self.crossfadeVolume       = min(1, vol)
                self.player.volume         = max(0, min(1, self.volume)) * self.crossfadeVolume
                self.orpheusEngine?.volume = self.crossfadeVolume
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.crossfadeVolume       = 1
            self.player.volume         = max(0, min(1, self.volume))
            self.orpheusEngine?.volume = 1
        }
    }

    // MARK: - Radio queue refresh

    private func fetchRadioTracks() {
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

    private static func radioTracks(seedTrack: Track?) async -> [Track] {
        // Try to get tracks for the seed track's genre; fall back to random songs.
        if let genreStr = seedTrack?.genres,
           let genreName = genreStr.split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
           !genreName.isEmpty,
           let genre = LibraryViewModel.shared.genres.first(where: { $0.name == genreName }) {
            let tracks = (try? await LyrionAPI.shared.getTracksForGenre(genreID: genre.id, count: 15)) ?? []
            if !tracks.isEmpty { return Array(tracks.shuffled().prefix(10)) }
        }
        // Fallback: random songs from library
        let songs = LibraryViewModel.shared.songs
        if !songs.isEmpty { return Array(songs.shuffled().prefix(10)) }
        return []
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            // BUG FIX: player can be nil if clearQueue() is called before any
            // track has played.  The original crashed here.  Safe no-op now.
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func removeItemNotificationObservers() {
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

    private func installPendingSeekWatchdog() {
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

    private func clearPendingSeekWatchdog() {
        pendingSeekWatchdogTask?.cancel()
        pendingSeekWatchdogTask = nil
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo(track: Track?) {
        let artworkURL = track.flatMap { LyrionAPI.shared.artworkURL(coverid: $0.coverid) }
        NowPlayingWidgetStore.shared.update(track: track, isPlaying: isPlaying, artworkURL: artworkURL)
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        artworkLoadID += 1
        let loadID  = artworkLoadID
        let trackID = track.id

        // BUG FIX: MPNowPlayingInfoPropertyMediaType was missing, which caused
        // CarPlay and the lock screen to display the wrong media type icon.
        // Setting it to .audio tells the system this is a music player.
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:              track.title,
            MPMediaItemPropertyArtist:             track.trackartist ?? track.albumartist ?? "",
            MPMediaItemPropertyAlbumTitle:         track.album ?? "",
            MPMediaItemPropertyComposer:           track.composer ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration:   duration,
            MPNowPlayingInfoPropertyPlaybackRate:        isPlaying ? 1.0 : 0.0,
            // DefaultPlaybackRate tells the system what "1×" means so the
            // lock-screen / CarPlay scrubber advances at the correct speed.
            // Without it iOS cannot interpolate elapsed time between updates
            // and the scrubber may drift or freeze.
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType:     MPNowPlayingInfoMediaType.audio.rawValue,
            // BUG FIX: QueueIndex / QueueCount let CarPlay display "3 of 12" etc.
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count
        ]
        // BUG FIX: The original conditioned MPMediaItemPropertyAlbumTrackNumber on
        // `track.year` being non-nil — clearly a copy-paste error that meant track
        // numbers were only populated when the year tag was present.  Track number
        // should always be set (it defaults to 0 when absent), regardless of year.
        info[MPMediaItemPropertyAlbumTrackNumber] = track.tracknum ?? 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : (isPaused ? .paused : .stopped)

        guard let coverid = track.coverid,
              let artURL  = LyrionAPI.shared.artworkURL(coverid: coverid) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let image = await self.loadImage(from: artURL) else { return }
            guard self.artworkLoadID == loadID, self.currentTrack?.id == trackID else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            updated[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
        }
    }

    private func refreshNowPlayingPlaybackState(force: Bool = false) {
        // Now Playing updates are visible on the lock screen, CarPlay, and
        // Control Center. Throttle periodic progress pushes to avoid needless
        // background CPU wakeups, while state changes call this with force=true.
        let uptime = ProcessInfo.processInfo.systemUptime
        if !force, uptime - lastNowPlayingRefreshUptime < 1.0 { return }
        lastNowPlayingRefreshUptime = uptime

        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : (isPaused ? .paused : .stopped)

        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration]         = duration > 0 ? duration : (currentTrack?.duration ?? 0)
        info[MPNowPlayingInfoPropertyPlaybackRate]        = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        // Keep queue index/count current in case tracks were added/removed.
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex]  = currentIndex
        info[MPNowPlayingInfoPropertyPlaybackQueueCount]  = queue.count
        MPNowPlayingInfoCenter.default().nowPlayingInfo   = info
    }
}
