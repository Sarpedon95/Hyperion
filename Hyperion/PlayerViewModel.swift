// ADDED: split into PlayerViewModel+Lifecycle, +NowPlayingInfo, +PlaybackAPI, +Queue, +Playback
// This file retains only: @Published state, private stored properties, init/deinit, scrobbling,
// state-save helpers, session restore, CarPlay notification, and queue-work-group bookkeeping.
import Foundation
import Combine
import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import WidgetKit

@MainActor
final class PlayerViewModel: ObservableObject {

    static let shared = PlayerViewModel()

    @Published var isPlaying: Bool = false
    // isPaused is not @Published — no view observes it; it's an internal
    // sentinel distinguishing "paused" from "never started".
    var isPaused: Bool = false
    @Published var currentTrack: Track? = nil {
        didSet {
            guard let track = currentTrack, track.id != oldValue?.id else { return }
            updateNowPlayingInfo(track: track)
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
    @Published var outputDeviceName: String = ""
    @Published var lmsAudioQuality: LMSAudioQuality? = nil
    @Published var isBitPerfect: Bool = false

    @Published var volume: Float = 1.0 {
        didSet {
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
            prefetchedNextAsset = nil
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

    @Published private(set) var queueWorkGroups: [QueueWorkGroup] = []
    @Published private(set) var upcomingWorkGroups: [QueueWorkGroup] = []

    // Internal (not private) so extension files in the same module can access them.
    let audioManager = AudioPlayerManager.shared
    var player: AVPlayer { audioManager.player }
    var playerItem: AVPlayerItem?
    var timeObserver: Any?
    var statusObservation: NSKeyValueObservation?
    var durationObservation: NSKeyValueObservation?
    var itemEndObservation: NSObjectProtocol?
    var itemFailureObservation: NSObjectProtocol?
    var itemStalledObservation: NSObjectProtocol?
    var activePlaybackID = UUID()
    var playbackURLCandidates: [URL] = []
    var playbackURLIndex: Int = 0
    var lastPlaybackErrorDescription: String?
    var pendingSeekTime: Double? = nil
    var artworkLoadID: Int = 0
    var originalQueueBeforeShuffle: [Track]?
    var interruptionObserver: NSObjectProtocol?
    var routeChangeObserver: NSObjectProtocol?
    var lifecycleObservers: [NSObjectProtocol] = []
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var isHandlingBackgroundTransition = false
    var timeControlObservation: NSKeyValueObservation?
    var lastNowPlayingRefreshUptime: TimeInterval = 0
    var wasPlayingBeforeInterruption = false
    var pendingSeekWatchdogTask: Task<Void, Never>?
    var playbackStartupWatchdogTask: Task<Void, Never>?
    var orpheusLoadTask: Task<Void, Never>?
    var playbackToggleDebounceTask: Task<Void, Never>?
    var isTransitioningPlayback = false

    // MARK: - Radio mode

    @Published var isRadioEnabled: Bool = {
        UserDefaults.standard.bool(forKey: "hyperion.radio.enabled")
    }() {
        didSet { UserDefaults.standard.set(isRadioEnabled, forKey: "hyperion.radio.enabled") }
    }

    var radioRefreshTask: Task<Void, Never>? = nil
    var lastSkipTimestamp: TimeInterval = 0

    // MARK: - Orpheus engine

    @Published var useOrpheusEngine: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "hyperion.orpheus.enabled") != nil
            ? ud.bool(forKey: "hyperion.orpheus.enabled")
            : true
    }() {
        didSet { UserDefaults.standard.set(useOrpheusEngine, forKey: "hyperion.orpheus.enabled") }
    }
    @Published var isPlaybackRoutedThroughOrpheus: Bool = false
    var isOrpheusActive: Bool { isPlaybackRoutedThroughOrpheus }
    var orpheusEngine: OrpheusPlaybackEngine?

    // MARK: - Orpheus diagnostics (mirrors engine state for debug UI)

    @Published var orpheusDidStartAudiblePlayback: Bool = false
    @Published var orpheusDecodedFormat: String = ""
    @Published var orpheusDurationKnown: Bool = false
    @Published var orpheusCanSeek: Bool = false
    @Published var orpheusPlaybackMode: OrpheusPlaybackMode = .fileLike
    @Published var orpheusStreamKind: OrpheusStreamKind = .unknown
    @Published var orpheusFallbackReason: String? = nil

    var prefetchedNextAsset: (trackID: Int, asset: AVURLAsset)? = nil
    var prefetchTask: Task<Void, Never>? = nil
    var lmsAudioQualityTask: Task<Void, Never>? = nil

    // MARK: - Playback profile

    let profileManager = PlaybackProfileManager.shared

    // MARK: - Gapless playback

    // AVPlayer path: pre-inserted AVPlayerItem for gapless AVQueuePlayer advance.
    var gaplessPreloadedItem: (trackID: Int, item: AVPlayerItem, url: URL)? = nil

    // Orpheus path: next-track engine pre-loaded and feeding PCM buffers before
    // the current track ends. Nil when no preload is in flight.
    var pendingOrpheusEngine:   OrpheusPlaybackEngine? = nil
    var pendingOrpheusLoadTask: Task<Void, Never>?     = nil

    // MARK: - Crossfade

    // crossfadeDuration is kept for backward compatibility with saved state.
    // Effective crossfade settings are resolved by PlaybackProfileManager.
    @Published var crossfadeDuration: Double = {
        UserDefaults.standard.double(forKey: "hyperion.crossfade.duration")
    }() {
        didSet { UserDefaults.standard.set(crossfadeDuration, forKey: "hyperion.crossfade.duration") }
    }
    var crossfadeVolume: Float = 1.0
    var crossfadeTask: Task<Void, Never>? = nil
    var isCrossfadingOut: Bool = false
    var radioEarlyFetchTriggered: Bool = false

    // MARK: - Artwork accent colour (extracted from album art for per-album theming)

    // ADDED: Task 9 — dominant colour from current artwork; falls back to .roonAccent.
    @Published var accentColor: Color = .roonAccent
    var accentColorExtractionTask: Task<Void, Never>?

    // MARK: - Last.fm scrobbling state
    var scrobbleTrackID: Int?
    var scrobbleStartTimestamp: TimeInterval = 0
    var scrobbleThreshold: Double = 0
    var hasScrobbled: Bool = false

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

    func checkScrobbleThreshold(_ time: Double) {
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

    func schedulePlaybackStateSave() {
        guard !queue.isEmpty else { return }
        PlaybackStateStore.shared.scheduleSave(
            queue:                      queue,
            currentIndex:               currentIndex,
            currentTime:                currentTime,
            isShuffle:                  isShuffle,
            repeatMode:                 repeatMode,
            originalQueueBeforeShuffle: originalQueueBeforeShuffle,
            currentWorkGroupID:         currentWorkGroup.map { $0.id }
        )
    }

    func savePlaybackStateNow() {
        guard !queue.isEmpty else { return }
        PlaybackStateStore.shared.saveNow(
            queue:                      queue,
            currentIndex:               currentIndex,
            currentTime:                currentTime,
            isShuffle:                  isShuffle,
            repeatMode:                 repeatMode,
            originalQueueBeforeShuffle: originalQueueBeforeShuffle,
            currentWorkGroupID:         currentWorkGroup.map { $0.id }
        )
    }

    // MARK: - Restore

    @discardableResult
    func restoreLastSession() -> Bool {
        guard let snap = PlaybackStateStore.shared.loadSnapshot(),
              !snap.queue.isEmpty else { return false }

        originalQueueBeforeShuffle = snap.originalQueueBeforeShuffle
        isShuffle                  = snap.isShuffle
        repeatMode                 = snap.repeatMode

        queue        = snap.queue
        currentIndex = max(0, min(snap.currentIndex, snap.queue.count - 1))

        currentTrack = snap.queue.indices.contains(currentIndex) ? snap.queue[currentIndex] : snap.queue.first
        currentTime  = snap.currentTime
        duration     = currentTrack?.duration ?? 0
        progress     = duration > 0 ? min(1, currentTime / duration) : 0
        pendingSeekTime = snap.currentTime > 1 ? snap.currentTime : nil

        syncCurrentWorkGroup()
        updateNowPlayingInfo(track: currentTrack)
        refreshNowPlayingPlaybackState(force: true)
        return true
    }

    private init() {
        _ = audioManager
        setupAudioSession()
        setupRemoteControls()
        setupAudioObservers()
        setupAppLifecycleObservers()
        logAudioSessionState("player-view-model-init")
    }

    deinit {
        Task { @MainActor in
            ServerLogStore.shared.error("PlayerViewModel deinit — audio manager lifetime was broken")
        }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver  { NotificationCenter.default.removeObserver(routeChangeObserver) }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let token = itemEndObservation     { NotificationCenter.default.removeObserver(token) }
        if let token = itemFailureObservation { NotificationCenter.default.removeObserver(token) }
        if let token = itemStalledObservation { NotificationCenter.default.removeObserver(token) }
        prefetchTask?.cancel()
        lmsAudioQualityTask?.cancel()
        accentColorExtractionTask?.cancel()
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

    func recomputeUpcoming() {
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
}
