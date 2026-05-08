import AVFoundation
import Foundation

// MARK: - Stream classification & playback mode

/// Whether the URL resolves to a finite file or an indefinite/chunked stream.
enum OrpheusStreamKind: CustomStringConvertible {
    case fileLike      // finite, known duration → seekable
    case streamLike    // indefinite duration → non-seekable, progressive read
    case unknown

    var description: String {
        switch self {
        case .fileLike:    return "file"
        case .streamLike:  return "stream"
        case .unknown:     return "unknown"
        }
    }
}

/// Selects which code path the buffer loop uses.
/// fileLike:  stop at EOS, short underrun retry, seekable
/// streaming: treat temporary nil as underrun (not EOS), long retry, no seek
enum OrpheusPlaybackMode: CustomStringConvertible {
    case fileLike
    case streaming

    var description: String {
        switch self {
        case .fileLike:   return "file"
        case .streaming:  return "streaming"
        }
    }
}

// MARK: - Internal reader state
// Accessed ONLY from feedQueue except for `generation`, which is written from MainActor
// as a lock-free cancellation signal and read on feedQueue. This intentional cross-thread
// access is safe on iOS's ARM architecture (cache-coherent stores).

private final class OPEReaderState {
    var assetReader: AVAssetReader?
    var readerOutput: AVAssetReaderTrackOutput?
    var isEOS: Bool = false
    var scheduledBufferCount: Int = 0
    var generation: Int = 0   // written MainActor (cancel signal), read feedQueue
    var isUnderrun: Bool = false
}

// MARK: - OrpheusPlaybackEngine

/// Streaming PCM playback engine that routes audio through the Orpheus DSP chain.
///
/// Decoding pipeline:
///   AVURLAsset (LMS HTTP) → AVAssetReader → interleaved Float32 PCM
///   → AVAudioPCMBuffer (de-interleaved) → AVAudioPlayerNode
///   → mainEQ → headphoneEQ → crossfeed → leveling → balance → output
///
/// Supports two modes:
///   fileLike  — finite, seekable asset (FLAC, ALAC, WAV, fixed-bitrate MP3/AAC)
///   streaming — indefinite HTTP response (LMS transcoding, chunked MP3/AAC)
///               AVAssetReader handles progressive downloads; duration unknown.
///
/// Threading model:
///   Public API is @MainActor. Buffer feeding runs on feedQueue (serial).
///   Routing all buffer-loop calls through a single serial queue eliminates
///   data races on OPEReaderState and AVAssetReaderTrackOutput.
///   MainActor callbacks are delivered via Task { @MainActor }.
///   Every callback Task is guarded by sessionID to prevent stale execution.
///
/// Lifecycle:
///   load() → play() → (seek() | pause() / resume())* → stop()
///   Do NOT call play() after stop() on the same instance; create a new engine.
///
/// Fallback conditions (caller should switch to AVPlayer):
///   - AirPlay output active at load time.
///   - Asset with no loadable audio track.
///   - AVAssetReader.startReading() fails after one retry.
///   - Streaming timeout: no data for 15 seconds.
///
@MainActor
final class OrpheusPlaybackEngine {

    // MARK: - Callbacks (all delivered on MainActor)

    var onTimeUpdate: ((Double) -> Void)?
    var onDurationKnown: ((Double) -> Void)?
    /// Fires true/false when buffering state changes.
    var onBufferingChanged: ((Bool) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Fires once when ≤3 s remain on a finite track. Used to pre-warm the
    /// next asset so the gap between Orpheus tracks is minimised.
    var onNearEnd: (() -> Void)?
    /// Fires true after first audible buffer plays. Fires false on stop().
    var onRoutingConfirmed: ((Bool) -> Void)?
    /// Fires once per load when the AVAssetTrack format is decoded.
    var onDecodedFormatKnown: ((String) -> Void)?

    // MARK: - Readable playback state

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var isBuffering: Bool = true

    /// Volume applied to the AVAudioPlayerNode (0–1). Ramp this for crossfade.
    var volume: Float = 1.0 {
        didSet { playerNode.volume = max(0, min(1, volume)) }
    }

    // ADDED: Task 11 — whether this stream supports crossfade.
    // Disabled for: streaming (no seek = no precise end-of-track timing),
    // short tracks (< 30 s would fade most of the content), and unknown duration.
    var crossfadeEligible: Bool {
        guard streamKind != .streamLike,     // streams have no precise EOS timing
              durationKnown                   // skip if duration is unknown
        else { return false }
        return true
    }

    // ADDED: Task 11 — volume ramp using a high-frequency task loop for smooth fade.
    // Equal-power curve: cos for fade-out, sin for fade-in (complementary half-power).
    @discardableResult
    func rampVolume(to targetVolume: Float, over duration: TimeInterval) -> Task<Void, Never> {
        let startVolume = volume
        let steps       = max(1, Int(duration / 0.016)) // ~60 fps
        return Task { @MainActor [weak self] in
            for i in 0..<steps {
                guard let self, !Task.isCancelled else { return }
                let t = Float(i + 1) / Float(steps)
                // Equal-power: fade-out (cos) when going to 0, fade-in (sin) when going to 1.
                let factor: Float = targetVolume < startVolume
                    ? cos(t * .pi / 2)
                    : sin(t * .pi / 2)
                self.volume = startVolume + (targetVolume - startVolume) * (
                    targetVolume < startVolume ? (1 - factor) : factor
                )
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self?.volume = targetVolume
        }
    }

    // MARK: - Diagnostics (MainActor-safe, exposed to debug UI)

    private(set) var playbackMode: OrpheusPlaybackMode = .fileLike
    private(set) var streamKind: OrpheusStreamKind = .unknown
    private(set) var durationKnown: Bool = false
    private(set) var canSeek: Bool = false
    private(set) var didStartAudiblePlayback: Bool = false
    private(set) var decodedFormat: String = ""
    private(set) var lastError: String? = nil

    // MARK: - Session tracking (prevents stale MainActor callbacks)
    //
    // Incremented on every play() and stop(). All Task { @MainActor } closures
    // created in play() capture the sessionID at the time of play() and bail
    // out if it has since changed. This eliminates the ghost-routing-confirmation
    // bug where onRoutingConfirmed(true) fired after stop() had already fired
    // onRoutingConfirmed(false).

    private var sessionID: Int = 0

    // MARK: - Constants

    nonisolated static let maxScheduledBuffers = 8
    nonisolated static let preloadFrames: Int = 88_200          // ~2 s @ 44.1 kHz
    nonisolated static let streamingTimeoutSeconds: Double = 15.0

    // MARK: - Audio graph (captured at init, safe to use from any queue)

    private let playerNode: AVAudioPlayerNode
    private let audioEngine: AVAudioEngine

    // MARK: - Reader state + feed queue

    private let rs = OPEReaderState()
    /// Serial queue for all buffer-loop operations.
    private let feedQueue = DispatchQueue(
        label: "com.hyperion.orpheus.feed",
        qos: .userInitiated
    )

    // MARK: - MainActor state

    private var currentAsset: AVURLAsset?
    private var cachedAudioTrack: AVAssetTrack?
    private var pcmFormat: AVAudioFormat?
    private var outputSettings: [String: Any] = [:]
    private var sampleRate: Double = 44_100
    private var seekOffset: Double = 0
    private var progressTimer: DispatchSourceTimer?
    private var preloadFramesAccumulated: Int = 0

    // MARK: - Init

    init(manager: AudioPlayerManager) {
        playerNode = manager.playerNode
        audioEngine = manager.engine
    }

    // MARK: - Load

    /// Loads the asset at `url`, classifies it as file-like or streaming, and
    /// prepares the AVAssetReader. Throws only on genuine failures; indefinite
    /// duration is handled as streaming mode (not a fallback condition).
    ///
    /// `preloadedAsset` — pass a prefetched `AVURLAsset` whose HTTP connection
    /// is already established. When provided the asset is used directly instead
    /// of creating a new one, eliminating one network round-trip.
    func load(url: URL, headers: [String: String], startTime: Double = 0,
              preloadedAsset: AVURLAsset? = nil) async throws {
        playbackMode  = .fileLike
        streamKind    = .unknown
        durationKnown = false
        canSeek       = false
        didStartAudiblePlayback = false
        decodedFormat = ""
        lastError     = nil

        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        sampleRate = sessionRate > 0 ? sessionRate : 44_100

        // Reuse a prefetched asset when available — its HTTP connection is already
        // established so .duration / .loadTracks resolve much faster.
        let asset: AVURLAsset
        if let preloaded = preloadedAsset {
            asset = preloaded
            ServerLogStore.shared.debug(
                "Orpheus load (prefetched): \(ServerLogStore.redactedURL(url.absoluteString))"
            )
        } else {
            let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
            asset = AVURLAsset(url: url, options: options)
            ServerLogStore.shared.debug(
                "Orpheus load: \(ServerLogStore.redactedURL(url.absoluteString))"
            )
        }
        currentAsset = asset

        // 1+2 — Duration & audio tracks concurrently (each is a separate network probe).
        let cmDur: CMTime
        let tracks: [AVAssetTrack]
        do {
            async let durLoad    = asset.load(.duration)
            async let tracksLoad = asset.loadTracks(withMediaType: .audio)
            (cmDur, tracks) = try await (durLoad, tracksLoad)
        } catch {
            throw OrpheusError.assetLoadFailed(error)
        }

        if cmDur.isValid && !cmDur.isIndefinite && cmDur.seconds > 0 {
            duration      = cmDur.seconds
            streamKind    = .fileLike
            playbackMode  = .fileLike
            durationKnown = true
            canSeek       = true
            onDurationKnown?(duration)
            ServerLogStore.shared.debug(
                "Orpheus: duration=\(String(format:"%.2f",duration))s  mode=fileLike  canSeek=true"
            )
        } else {
            streamKind   = .streamLike
            playbackMode = .streaming
            ServerLogStore.shared.info(
                "Orpheus: indefinite duration — mode=streaming  canSeek=false"
            )
        }

        guard let audioTrack = tracks.first else {
            throw OrpheusError.noAudioTrack
        }
        cachedAudioTrack = audioTrack

        // 3 — Format detection
        let outputChannels: Int
        do {
            let descs = try await audioTrack.load(.formatDescriptions)
            if let desc = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                let codec  = ope_fourCharCodeToString(asbd.pointee.mFormatID)
                let srcHz  = asbd.pointee.mSampleRate
                let srcCh  = asbd.pointee.mChannelsPerFrame
                outputChannels = Int(srcCh) == 1 ? 2 : min(2, Int(srcCh))
                decodedFormat  = "\(codec) @ \(Int(srcHz)) Hz, \(srcCh)ch"
                onDecodedFormatKnown?(decodedFormat)
                ServerLogStore.shared.info(
                    "Orpheus source: \(decodedFormat) → Float32 @ \(Int(sampleRate)) Hz, \(outputChannels)ch  mode=\(playbackMode)"
                )
            } else {
                outputChannels = 2
                decodedFormat  = "unknown"
                ServerLogStore.shared.warn("Orpheus: no format descriptions on audio track")
            }
        } catch {
            outputChannels = 2
            decodedFormat  = "unknown (load error)"
            ServerLogStore.shared.warn("Orpheus: format description load error: \(error.localizedDescription)")
        }

        // 4 — PCM output settings
        outputSettings = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             sampleRate,
            AVNumberOfChannelsKey:       outputChannels,
            AVLinearPCMBitDepthKey:      32,
            AVLinearPCMIsFloatKey:       true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey:   false
        ]
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(outputChannels),
            interleaved: false
        ) else {
            throw OrpheusError.formatSetupFailed
        }
        pcmFormat = fmt

        // 5 — Build the reader (with one automatic retry on failure)
        try await buildReader(asset: asset, audioTrack: audioTrack, fromTime: startTime)
        seekOffset = startTime

        ServerLogStore.shared.info(
            "Orpheus: reader ready  mode=\(playbackMode)  (routing confirmation deferred to first audio)"
        )
    }

    // MARK: - Playback control

    /// Starts buffer feeding without resetting the player node.
    /// Call this only when the node is already playing the previous track's tail buffers
    /// (i.e. during a gapless track transition). `preloadTarget = 0` suppresses the
    /// `node.play()` call so the already-running node is not disturbed.
    func playGapless() {
        guard let fmt = pcmFormat else {
            let msg = "OrpheusPlaybackEngine.playGapless() called before load()"
            lastError = msg
            onError?(msg)
            return
        }

        sessionID += 1
        let sid = sessionID

        isPlaying               = true
        isBuffering             = false
        didStartAudiblePlayback = true
        preloadFramesAccumulated = 0

        let node   = playerNode
        let state  = rs
        let format = fmt
        let mode   = playbackMode
        let fq     = feedQueue

        state.generation += 1
        let gen = state.generation

        feedQueue.async {
            guard state.generation == gen else { return }
            state.isEOS               = false
            state.scheduledBufferCount = 0
            state.isUnderrun          = false

            OPEBufferLoop.feed(
                state:     state,
                node:      node,
                format:    format,
                gen:       gen,
                mode:      mode,
                feedQueue: fq,
                onStart:   {},   // node is already playing — no-op
                onEnd: {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.isPlaying = false
                        self.stopProgressTimer()
                        self.onPlaybackEnded?()
                    }
                },
                onError: { msg in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.lastError = msg
                        self.onError?(msg)
                    }
                },
                onUnderrun: {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.isBuffering = true
                        self.onBufferingChanged?(true)
                    }
                },
                onRecovery: {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.isBuffering = false
                        self.onBufferingChanged?(false)
                    }
                },
                preloadTarget: 0   // skip node.play() — node is already running
            )
        }

        startProgressTimer()
        onRoutingConfirmed?(true)
    }

    /// Adjust seekOffset so that time reads correctly after a gapless handoff.
    /// `nodeElapsedAtHandoff` is the cumulative AVAudioPlayerNode sampleTime / sampleRate
    /// at the moment the previous track's last buffer finished playing.
    func configureGaplessSeekOffset(nodeElapsedAtHandoff: Double) {
        seekOffset = -nodeElapsedAtHandoff
    }

    /// Cancel the buffer loop and tear down readers without stopping or resetting
    /// the player node. Used during gapless handoff so the next engine's already-
    /// scheduled buffers continue playing uninterrupted.
    func stopWithoutResettingNode() {
        sessionID += 1
        isPlaying               = false
        isBuffering             = false
        didStartAudiblePlayback = false
        stopProgressTimer()

        let state = rs
        state.generation += 1
        feedQueue.async {
            state.isEOS               = true
            state.isUnderrun          = false
            state.scheduledBufferCount = 0
            state.assetReader?.cancelReading()
            state.assetReader  = nil
            state.readerOutput = nil
        }

        onRoutingConfirmed?(false)
        onTimeUpdate         = nil
        onDurationKnown      = nil
        onBufferingChanged   = nil
        onPlaybackEnded      = nil
        onError              = nil
        onNearEnd            = nil
        onRoutingConfirmed   = nil
        onDecodedFormatKnown = nil
    }

    /// Starts playback from the reader's current position.
    /// Also used to restart after an interruption that stopped the AVAudioEngine.
    func play() {
        guard let fmt = pcmFormat else {
            let msg = "OrpheusPlaybackEngine: play() called before load()"
            lastError = msg
            onError?(msg)
            return
        }

        // Increment sessionID before any async work. All Task { @MainActor } closures
        // capture this value and bail out if sessionID has changed by the time they run.
        // This prevents ghost callbacks from stale buffer loops.
        sessionID += 1
        let sid = sessionID

        isPlaying    = true
        isBuffering  = true
        didStartAudiblePlayback = false
        preloadFramesAccumulated = 0
        onBufferingChanged?(true)

        if !audioEngine.isRunning {
            do { try audioEngine.start() }
            catch {
                isPlaying = false
                isBuffering = false
                let msg = "Cannot start AVAudioEngine: \(error.localizedDescription)"
                lastError = msg
                onError?(msg)
                return
            }
        }

        playerNode.stop()
        playerNode.reset()

        let node     = playerNode
        let state    = rs
        let format   = fmt
        let mode     = playbackMode
        let fq       = feedQueue

        // Increment generation on MainActor as a lock-free cancellation signal.
        // The feed loop running on feedQueue polls this value and exits immediately
        // when it changes, preventing up to 15 seconds of blocking on stop().
        state.generation += 1
        let gen = state.generation

        // Reset the rest of the reader state on feedQueue where it's owned.
        feedQueue.async {
            guard state.generation == gen else { return }
            state.isEOS             = false
            state.scheduledBufferCount = 0
            state.isUnderrun        = false

            OPEBufferLoop.feed(
                state:   state,
                node:    node,
                format:  format,
                gen:     gen,
                mode:    mode,
                feedQueue: fq,
                onStart: {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.didStartAudiblePlayback = true
                        self.isBuffering  = false
                        self.onBufferingChanged?(false)
                        self.onRoutingConfirmed?(true)
                        self.startProgressTimer()
                        ServerLogStore.shared.info(
                            "Orpheus: first audio playing — routing confirmed  mode=\(mode)"
                        )
                    }
                },
                onEnd: {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.isPlaying = false
                        self.stopProgressTimer()
                        self.onPlaybackEnded?()
                    }
                },
                onError: { msg in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.lastError = msg
                        self.onError?(msg)
                    }
                },
                onUnderrun: {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.isBuffering = true
                        self.onBufferingChanged?(true)
                        ServerLogStore.shared.warn("Orpheus: underrun — waiting for data  mode=\(mode)")
                    }
                },
                onRecovery: {
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == sid else { return }
                        self.isBuffering = false
                        self.onBufferingChanged?(false)
                        ServerLogStore.shared.info("Orpheus: recovered from underrun  mode=\(mode)")
                    }
                },
                preloadTarget: OPEBufferLoop.preloadTarget
            )
        }
    }

    /// Lightweight resume after pause(). Resumes the playerNode in place without
    /// resetting state or restarting the buffer loop.
    ///
    /// If the AVAudioEngine was stopped by an interruption (phone call, Siri), the
    /// node's buffer queue is gone — this method restarts via play() instead, after
    /// updating seekOffset so progress display stays correct.
    func resume() {
        guard !isPlaying, pcmFormat != nil else { return }

        if audioEngine.isRunning {
            // Simple path: node was paused, not stopped. Resume exactly where it was.
            isPlaying = true
            playerNode.play()
            startProgressTimer()
        } else {
            // Engine was stopped by an OS interruption. Preserve the current playback
            // position then do a full restart (rebuilds the buffer pipeline).
            seekOffset = currentTime
            play()
        }
    }

    func pause() {
        isPlaying = false
        playerNode.pause()
        stopProgressTimer()
    }

    func stop() {
        // Increment sessionID first. Any Task { @MainActor } closures from the
        // current buffer loop that haven't run yet will see the mismatch and exit.
        sessionID += 1

        isPlaying   = false
        isBuffering = false
        didStartAudiblePlayback = false
        stopProgressTimer()
        playerNode.stop()
        playerNode.reset()

        // Signal the feedQueue to cancel any in-flight buffer loop and tear down
        // the reader. Writing generation from MainActor is an intentional lock-free
        // cancel signal; the feed loop polls it on every 50 ms sleep iteration.
        let state = rs
        state.generation += 1
        feedQueue.async {
            state.isEOS  = true
            state.isUnderrun = false
            state.scheduledBufferCount = 0
            state.assetReader?.cancelReading()
            state.assetReader  = nil
            state.readerOutput = nil
        }

        onRoutingConfirmed?(false)

        // Nil out all callbacks so no future stale invocation can mutate state.
        onTimeUpdate        = nil
        onDurationKnown     = nil
        onBufferingChanged  = nil
        onPlaybackEnded     = nil
        onError             = nil
        onNearEnd           = nil
        onRoutingConfirmed  = nil
        onDecodedFormatKnown = nil
    }

    /// Seek is only valid for fileLike assets. For streaming this is a no-op
    /// (canSeek = false; UI should disable the seek control).
    func seek(to time: Double) {
        guard canSeek, durationKnown else {
            ServerLogStore.shared.warn(
                "Orpheus: seek ignored (canSeek=\(canSeek) durationKnown=\(durationKnown) mode=\(playbackMode))"
            )
            return
        }

        guard let asset = currentAsset, let track = cachedAudioTrack, let fmt = pcmFormat else {
            return
        }

        let wasPlaying = isPlaying
        isPlaying    = false
        isBuffering  = true
        stopProgressTimer()
        playerNode.stop()
        playerNode.reset()
        onBufferingChanged?(true)
        seekOffset  = time
        currentTime = time
        onTimeUpdate?(time)

        // Capture current sessionID for the seek's buffer loop callbacks.
        // play()/stop() will increment sessionID, invalidating these closures.
        let sid = sessionID

        let state    = rs
        let node     = playerNode
        let format   = fmt
        let fq       = feedQueue

        // Cancel the current feed loop by incrementing generation on MainActor.
        state.generation += 1

        feedQueue.async {
            state.isEOS  = true
            state.isUnderrun = false
            state.scheduledBufferCount = 0
            state.assetReader?.cancelReading()
            state.assetReader  = nil
            state.readerOutput = nil
        }

        Task { @MainActor [weak self] in
            guard let self, self.currentAsset === asset else { return }
            do {
                try await self.buildReader(asset: asset, audioTrack: track, fromTime: time)
                guard self.currentAsset === asset else { return }

                // Increment generation for the new feed loop on MainActor.
                state.generation += 1
                let gen = state.generation

                feedQueue.async {
                    guard state.generation == gen else { return }
                    state.isEOS  = false
                    state.isUnderrun = false
                    state.scheduledBufferCount = 0
                }

                if wasPlaying {
                    self.isPlaying = true
                    if !self.audioEngine.isRunning { try? self.audioEngine.start() }

                    // Buffer loop calls node.play() once preload target is met.
                    // Never call node.play() here — that would start the node before
                    // any buffers are scheduled, producing a brief silence.
                    fq.async { [weak self] in
                        OPEBufferLoop.feed(
                            state:     state,
                            node:      node,
                            format:    format,
                            gen:       gen,
                            mode:      .fileLike,   // seek only valid for fileLike
                            feedQueue: fq,
                            onStart: {
                                Task { @MainActor [weak self] in
                                    guard let self, self.sessionID == sid else { return }
                                    self.isBuffering = false
                                    self.onBufferingChanged?(false)
                                    self.startProgressTimer()
                                }
                            },
                            onEnd: {
                                Task { @MainActor [weak self] in
                                    guard let self, self.sessionID == sid else { return }
                                    self.isPlaying = false
                                    self.stopProgressTimer()
                                    self.onPlaybackEnded?()
                                }
                            },
                            onError: { msg in
                                Task { @MainActor [weak self] in
                                    guard let self, self.sessionID == sid else { return }
                                    self.lastError = msg
                                    self.onError?(msg)
                                }
                            },
                            onUnderrun: {},
                            onRecovery: {},
                            preloadTarget: OPEBufferLoop.preloadTarget
                        )
                    }
                } else {
                    // Seeked while paused. Just update state; playback starts on resume.
                    self.isBuffering = false
                    self.onBufferingChanged?(false)
                }
            } catch {
                let msg = "Seek rebuild failed: \(error.localizedDescription)"
                self.lastError = msg
                self.onError?(msg)
            }
        }
    }

    // MARK: - Private helpers

    private func buildReader(
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        fromTime: Double
    ) async throws {
        // Drain any in-flight feedQueue work before swapping the reader.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            feedQueue.async { cont.resume() }
        }

        // First attempt.
        do {
            let (reader, output) = try makeReaderAndOutput(
                asset: asset, audioTrack: audioTrack, fromTime: fromTime
            )
            let state = rs
            feedQueue.async {
                state.assetReader  = reader
                state.readerOutput = output
            }
            ServerLogStore.shared.debug(
                "Orpheus: reader started  fromTime=\(String(format:"%.2f",fromTime))s  mode=\(playbackMode)"
            )
            return
        } catch {
            ServerLogStore.shared.warn(
                "Orpheus: reader start failed (\(error.localizedDescription)) — retrying in 300 ms"
            )
        }

        // One retry after a brief pause (handles transient LMS / network hiccups).
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard currentAsset === asset else {
            throw OrpheusError.readerStartFailed(nil)
        }

        do {
            let (reader, output) = try makeReaderAndOutput(
                asset: asset, audioTrack: audioTrack, fromTime: fromTime
            )
            let state = rs
            feedQueue.async {
                state.assetReader  = reader
                state.readerOutput = output
            }
            ServerLogStore.shared.info(
                "Orpheus: reader started on retry  mode=\(playbackMode)"
            )
        } catch {
            ServerLogStore.shared.error(
                "Orpheus: reader retry also failed: \(error.localizedDescription)"
            )
            throw OrpheusError.readerStartRetryFailed(error)
        }
    }

    private func makeReaderAndOutput(
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        fromTime: Double
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw OrpheusError.readerCreationFailed(error) }

        // Time range is only valid for fileLike assets with a known duration.
        if fromTime > 0, playbackMode == .fileLike, duration > 0 {
            let start = CMTime(seconds: fromTime, preferredTimescale: 44_100)
            let end   = CMTime(seconds: duration, preferredTimescale: 44_100)
            reader.timeRange = CMTimeRange(start: start, end: end)
        }

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw OrpheusError.readerSetupFailed }
        reader.add(output)

        guard reader.startReading() else {
            throw OrpheusError.readerStartFailed(reader.error)
        }
        return (reader, output)
    }

    // MARK: - Progress timer

    func startProgressTimer() {
        stopProgressTimer()
        let node    = playerNode
        let mode    = playbackMode
        let timer   = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick(node: node, mode: mode) }
        timer.resume()
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func tick(node: AVAudioPlayerNode, mode: OrpheusPlaybackMode) {
        guard isPlaying,
              let nodeTime   = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0 else { return }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        switch mode {
        case .fileLike:
            currentTime = min(duration, seekOffset + elapsed)
        case .streaming:
            currentTime = elapsed
        }
        onTimeUpdate?(currentTime)
        // Fire onNearEnd once when ≤3 s remain on a finite track so the caller
        // can pre-warm the next asset and reduce the inter-track gap.
        if durationKnown, duration > 0, (duration - currentTime) <= 3, let cb = onNearEnd {
            onNearEnd = nil   // fire exactly once
            cb()
        }
    }
}

// MARK: - Static buffer loop

private enum OPEBufferLoop {

    static let preloadTarget: Int = OrpheusPlaybackEngine.preloadFrames
    private static let maxBuffers: Int = OrpheusPlaybackEngine.maxScheduledBuffers

    /// Fills the AVAudioPlayerNode buffer queue.
    /// Must be called from feedQueue; all recursive calls also go through feedQueue.async.
    static func feed(
        state:         OPEReaderState,
        node:          AVAudioPlayerNode,
        format:        AVAudioFormat,
        gen:           Int,
        mode:          OrpheusPlaybackMode,
        feedQueue:     DispatchQueue,
        onStart:       @escaping () -> Void,
        onEnd:         @escaping () -> Void,
        onError:       @escaping (String) -> Void,
        onUnderrun:    @escaping () -> Void,
        onRecovery:    @escaping () -> Void,
        preloadTarget: Int
    ) {
        var framesScheduled   = 0
        var conversionFails   = 0

        while state.scheduledBufferCount < maxBuffers && !state.isEOS {
            guard state.generation == gen,
                  let reader = state.assetReader,
                  let output = state.readerOutput else {
                state.isEOS = true
                break
            }

            guard reader.status == .reading else {
                handleReaderTermination(reader: reader, state: state, onError: onError)
                break
            }

            guard let sb = nextSampleBuffer(
                from: output, reader: reader,
                state: state, gen: gen,
                mode: mode,
                onError: onError, onUnderrun: onUnderrun, onRecovery: onRecovery
            ) else {
                break
            }

            guard let pcm = convertToPCM(sb, format: format) else {
                conversionFails += 1
                if conversionFails > 10 {
                    onError("Orpheus: \(conversionFails) consecutive PCM conversion failures")
                    state.isEOS = true
                }
                continue
            }
            conversionFails = 0

            framesScheduled += Int(pcm.frameLength)
            state.scheduledBufferCount += 1

            node.scheduleBuffer(pcm) {
                guard state.generation == gen else { return }
                state.scheduledBufferCount = max(0, state.scheduledBufferCount - 1)

                let eos       = state.isEOS
                let remaining = state.scheduledBufferCount

                if eos && remaining == 0 {
                    onEnd()
                } else if !eos {
                    feedQueue.async {
                        OPEBufferLoop.feed(
                            state:         state,
                            node:          node,
                            format:        format,
                            gen:           gen,
                            mode:          mode,
                            feedQueue:     feedQueue,
                            onStart:       {},
                            onEnd:         onEnd,
                            onError:       onError,
                            onUnderrun:    onUnderrun,
                            onRecovery:    onRecovery,
                            preloadTarget: 0
                        )
                    }
                }
            }
        }

        let hasEnough = framesScheduled >= preloadTarget || state.isEOS
        if preloadTarget > 0 && hasEnough && state.scheduledBufferCount > 0 {
            node.play()
            onStart()
        } else if preloadTarget > 0 && state.isEOS && state.scheduledBufferCount == 0 {
            onEnd()
        }
    }

    // MARK: Reader state helpers

    private static func handleReaderTermination(
        reader: AVAssetReader,
        state:  OPEReaderState,
        onError: @escaping (String) -> Void
    ) {
        state.isEOS = true
        switch reader.status {
        case .completed, .cancelled:
            break
        case .failed:
            onError("Orpheus: reader failed: \(reader.error?.localizedDescription ?? "unknown")")
        default:
            break
        }
    }

    /// Returns the next CMSampleBuffer, waiting on nil depending on mode:
    ///
    /// fileLike:  retry for up to ~1 s (transient LMS decode hiccup).
    /// streaming: retry for up to `streamingTimeout` s (normal for chunked HTTP).
    ///            Signals onUnderrun when wait exceeds 0.5 s; signals onRecovery
    ///            when data arrives after an underrun.
    private static func nextSampleBuffer(
        from output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        state:  OPEReaderState,
        gen:    Int,
        mode:   OrpheusPlaybackMode,
        onError:    @escaping (String) -> Void,
        onUnderrun: @escaping () -> Void,
        onRecovery: @escaping () -> Void
    ) -> CMSampleBuffer? {
        // Fast path: data is ready immediately.
        if let sb = output.copyNextSampleBuffer() { return sb }

        // nil — check reader state before entering retry loop.
        switch reader.status {
        case .completed, .cancelled:
            state.isEOS = true
            return nil
        case .failed:
            state.isEOS = true
            onError("Orpheus: decode failed: \(reader.error?.localizedDescription ?? "unknown")")
            return nil
        case .reading:
            break
        case .unknown:
            state.isEOS = true
            return nil
        @unknown default:
            state.isEOS = true
            return nil
        }

        // Retry loop — duration depends on mode.
        let timeout: Double
        switch mode {
        case .fileLike:  timeout = 1.0
        case .streaming: timeout = OrpheusPlaybackEngine.streamingTimeoutSeconds
        }

        let deadline          = Date().addingTimeInterval(timeout)
        let underrunThreshold = 0.5

        repeat {
            // Check generation first — fast exit when stop() is called.
            guard state.generation == gen else {
                state.isEOS = true
                return nil
            }

            Thread.sleep(forTimeInterval: 0.05)

            if let sb = output.copyNextSampleBuffer() {
                if state.isUnderrun {
                    state.isUnderrun = false
                    onRecovery()
                }
                return sb
            }

            if reader.status != .reading {
                handleReaderTermination(reader: reader, state: state, onError: onError)
                return nil
            }

            let waited = timeout - deadline.timeIntervalSinceNow
            if !state.isUnderrun && waited >= underrunThreshold {
                state.isUnderrun = true
                onUnderrun()
            }

        } while Date() < deadline

        // Timed out.
        state.isEOS = true
        state.isUnderrun = false
        switch mode {
        case .fileLike:
            onError("Orpheus: file read stall — no data after \(String(format:"%.0f",timeout))s")
        case .streaming:
            onError("Orpheus: streaming timeout — no data for \(String(format:"%.0f",timeout))s (fallback required)")
        }
        return nil
    }

    // MARK: PCM conversion

    private static func convertToPCM(_ sb: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let fc = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard fc > 0 else { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: fc) else { return nil }
        buf.frameLength = fc

        var abl  = AudioBufferList()
        var blk: CMBlockBuffer? = nil
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blk
        )
        guard st == noErr,
              let src  = abl.mBuffers.mData,
              let chL  = buf.floatChannelData?[0],
              let chR  = buf.floatChannelData?[1] else { return nil }

        let p  = src.assumingMemoryBound(to: Float.self)
        let ch = Int(format.channelCount)
        if ch >= 2 {
            for i in 0..<Int(fc) {
                chL[i] = p[i * ch]
                chR[i] = p[i * ch + 1]
            }
        } else {
            for i in 0..<Int(fc) { chL[i] = p[i]; chR[i] = p[i] }
        }
        _ = blk
        return buf
    }
}

// MARK: - Errors

enum OrpheusError: LocalizedError {
    case liveStreamUnsupported      // kept for source-compatibility; no longer thrown
    case invalidDuration
    case noAudioTrack
    case assetLoadFailed(Error)
    case readerCreationFailed(Error)
    case readerSetupFailed
    case readerStartFailed(Error?)
    case readerStartRetryFailed(Error)
    case formatSetupFailed
    case decodeFailure(String)
    case bufferConversionFailure
    case streamEndedUnexpectedly
    case streamingTimeout
    case seekNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .liveStreamUnsupported:            return "Live/indefinite streams are not supported by this reader"
        case .invalidDuration:                  return "Audio asset has no finite duration"
        case .noAudioTrack:                     return "No audio track found in asset"
        case .assetLoadFailed(let e):           return "Asset load failed: \(e.localizedDescription)"
        case .readerCreationFailed(let e):      return "AVAssetReader creation failed: \(e.localizedDescription)"
        case .readerSetupFailed:                return "Cannot configure AVAssetReader output"
        case .readerStartFailed(let e):         return "AVAssetReader.startReading() failed: \(e?.localizedDescription ?? "unknown")"
        case .readerStartRetryFailed(let e):    return "AVAssetReader retry also failed: \(e.localizedDescription)"
        case .formatSetupFailed:                return "Failed to create AVAudioFormat for PCM output"
        case .decodeFailure(let msg):           return "Decode failure: \(msg)"
        case .bufferConversionFailure:          return "PCM buffer conversion failed"
        case .streamEndedUnexpectedly:          return "Stream ended before expected position"
        case .streamingTimeout:                 return "No audio data received within timeout period"
        case .seekNotSupported(let reason):     return "Seek not supported: \(reason)"
        }
    }
}

// MARK: - Utilities

private func ope_fourCharCodeToString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >>  8) & 0xFF),
        UInt8( code        & 0xFF)
    ]
    if let str = String(bytes: bytes, encoding: .ascii) {
        let printable = str.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "." }
        if !printable.trimmingCharacters(in: .whitespaces).isEmpty {
            return str.trimmingCharacters(in: .whitespaces)
        }
    }
    return String(format: "0x%08X", code)
}
