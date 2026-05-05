import AVFoundation
import Foundation

// MARK: - Internal reader state
// Accessed ONLY from OrpheusPlaybackEngine.readingQueue. Not thread-safe by itself.
private final class OPEReaderState {
    var assetReader: AVAssetReader?
    var readerOutput: AVAssetReaderTrackOutput?
    var isEOS: Bool = false
    var scheduledBufferCount: Int = 0
    var generation: Int = 0
}

// MARK: - OrpheusPlaybackEngine

/// Streaming PCM playback engine that routes audio through the Orpheus DSP chain.
///
/// Decoding pipeline:
///   AVURLAsset (LMS HTTP) → AVAssetReader → interleaved Float32 PCM
///   → AVAudioPCMBuffer (de-interleaved) → AVAudioPlayerNode
///   → mainEQ → headphoneEQ → crossfeed → leveling → balance → output
///
/// Threading model:
///   - Public API is @MainActor.
///   - Buffer reading runs on readingQueue (blocking I/O off the cooperative pool).
///   - Completion handlers hop back to MainActor via Task { @MainActor }.
///
/// Fallback conditions (caller must detect and switch to AVPlayer):
///   - AirPlay output (AVAudioEngine does not support AirPlay-routed output on all
///     device/OS combinations — hand off to AVPlayer for reliable AirPlay.)
///   - Asset load failure (network, format unsupported by AVFoundation).
///   - AVAssetReader start failure (live/infinite streams, DRM content).
///
@MainActor
final class OrpheusPlaybackEngine {

    // MARK: - Callbacks (all delivered on MainActor)

    var onTimeUpdate: ((Double) -> Void)?
    var onDurationKnown: ((Double) -> Void)?
    var onBufferingChanged: ((Bool) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Fires when audio is confirmed routed through the DSP chain (true) or not (false).
    var onRoutingConfirmed: ((Bool) -> Void)?

    // MARK: - Readable state

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var isBuffering: Bool = true

    // MARK: - Private constants

    private static let maxScheduledBuffers = 8
    private static let preloadFrames: Int  = 88_200   // ~2 s @ 44 100 Hz

    // MARK: - Audio graph references (captured at init, used in background closures)

    private let playerNode: AVAudioPlayerNode
    private let audioEngine: AVAudioEngine

    // MARK: - Reader state (accessed from readingQueue ONLY)

    private let rs = OPEReaderState()
    private let readingQueue = DispatchQueue(
        label: "com.hyperion.orpheus.reader",
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

    /// Loads the asset at `url` and prepares the reader from `startTime`.
    /// Throws `OrpheusError` on any failure; caller should fall back to AVPlayer.
    func load(url: URL, headers: [String: String], startTime: Double = 0) async throws {
        // Pick sample rate from the live audio session so we match the hardware.
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        sampleRate = sessionRate > 0 ? sessionRate : 44_100

        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        currentAsset = asset

        // 1 — Duration
        do {
            let cmDur = try await asset.load(.duration)
            guard cmDur.isValid, !cmDur.isIndefinite, cmDur.seconds > 0 else {
                throw OrpheusError.invalidDuration
            }
            duration = cmDur.seconds
            onDurationKnown?(duration)
        } catch let e as OrpheusError {
            throw e
        } catch {
            throw OrpheusError.assetLoadFailed(error)
        }

        // 2 — Audio tracks
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw OrpheusError.assetLoadFailed(error)
        }
        guard let audioTrack = tracks.first else {
            throw OrpheusError.noAudioTrack
        }
        cachedAudioTrack = audioTrack

        // 3 — Source channel count (mono upmixed to stereo for DSP chain)
        let outputChannels: Int
        do {
            let descs = try await audioTrack.load(.formatDescriptions)
            if let desc = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                outputChannels = min(2, max(1, Int(asbd.pointee.mChannelsPerFrame))) == 1 ? 2 : 2
            } else {
                outputChannels = 2
            }
        } catch {
            outputChannels = 2
        }

        // 4 — PCM output format: 32-bit float, interleaved (de-interleaved on conversion)
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

        // 5 — Build the reader
        try await buildReader(asset: asset, audioTrack: audioTrack, fromTime: startTime)
        seekOffset = startTime
        onRoutingConfirmed?(true)
    }

    // MARK: - Playback control

    func play() {
        guard let fmt = pcmFormat else {
            onError?("OrpheusPlaybackEngine: play() called before load()")
            return
        }

        isPlaying    = true
        isBuffering  = true
        preloadFramesAccumulated = 0
        onBufferingChanged?(true)

        // Ensure the AVAudioEngine is running before scheduling buffers.
        if !audioEngine.isRunning {
            do { try audioEngine.start() }
            catch {
                isPlaying = false
                onError?("Cannot start AVAudioEngine: \(error.localizedDescription)")
                return
            }
        }

        // Reset node so stale buffers from a previous track are discarded.
        playerNode.stop()
        playerNode.reset()

        // Capture what the background queue needs (no self references in closure).
        let node        = playerNode
        let state       = rs
        let format      = fmt
        let settings    = outputSettings
        let gen         = { () -> Int in state.generation += 1; return state.generation }()
        state.isEOS             = false
        state.scheduledBufferCount = 0

        readingQueue.async { [weak self] in
            OPEBufferLoop.feed(
                state:   state,
                node:    node,
                format:  format,
                gen:     gen,
                onStart: {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isBuffering = false
                        self.onBufferingChanged?(false)
                        self.startProgressTimer()
                    }
                },
                onEnd: {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isPlaying = false
                        self.stopProgressTimer()
                        self.onPlaybackEnded?()
                    }
                },
                onError: { msg in
                    Task { @MainActor [weak self] in self?.onError?(msg) }
                },
                preloadTarget: OPEBufferLoop.preloadTarget
            )
            _ = settings  // referenced to keep alive
        }
    }

    func pause() {
        isPlaying = false
        playerNode.pause()
        stopProgressTimer()
    }

    func stop() {
        isPlaying  = false
        isBuffering = false
        stopProgressTimer()
        playerNode.stop()
        playerNode.reset()

        let state = rs
        readingQueue.async {
            state.generation += 1   // invalidate all pending completion handlers
            state.isEOS = true
            state.scheduledBufferCount = 0
            state.assetReader?.cancelReading()
            state.assetReader  = nil
            state.readerOutput = nil
        }

        onRoutingConfirmed?(false)
    }

    func seek(to time: Double) {
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

        let state    = rs
        let node     = playerNode
        let format   = fmt
        let settings = outputSettings

        // Invalidate pending completion handlers immediately.
        readingQueue.async {
            state.generation += 1
            state.isEOS = true
            state.scheduledBufferCount = 0
            state.assetReader?.cancelReading()
            state.assetReader  = nil
            state.readerOutput = nil
        }

        // Rebuild the reader from the seek position (async, on MainActor).
        Task { @MainActor [weak self] in
            guard let self, self.currentAsset === asset else { return }
            do {
                try await self.buildReader(asset: asset, audioTrack: track, fromTime: time)
                guard self.currentAsset === asset else { return }  // guard against concurrent load
                let gen = { () -> Int in state.generation += 1; return state.generation }()
                state.isEOS = false
                state.scheduledBufferCount = 0
                self.preloadFramesAccumulated = 0

                if wasPlaying {
                    self.isPlaying = true
                    if !self.audioEngine.isRunning { try? self.audioEngine.start() }
                    node.play()
                    self.readingQueue.async { [weak self] in
                        OPEBufferLoop.feed(
                            state:   state,
                            node:    node,
                            format:  format,
                            gen:     gen,
                            onStart: {
                                Task { @MainActor [weak self] in
                                    self?.isBuffering = false
                                    self?.onBufferingChanged?(false)
                                    self?.startProgressTimer()
                                }
                            },
                            onEnd: {
                                Task { @MainActor [weak self] in
                                    self?.isPlaying = false
                                    self?.stopProgressTimer()
                                    self?.onPlaybackEnded?()
                                }
                            },
                            onError: { msg in Task { @MainActor [weak self] in self?.onError?(msg) } },
                            preloadTarget: 0  // post-seek: start immediately, no pre-buffer wait
                        )
                        _ = settings
                    }
                }
            } catch {
                self.onError?("Seek failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private helpers

    private func buildReader(
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        fromTime: Double
    ) async throws {
        // Wait for old reader to be torn down on readingQueue before creating a new one.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readingQueue.async { cont.resume() }
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw OrpheusError.readerCreationFailed(error) }

        if fromTime > 0 {
            let start = CMTime(seconds: fromTime, preferredTimescale: 44_100)
            let end   = CMTime(seconds: duration,  preferredTimescale: 44_100)
            reader.timeRange = CMTimeRange(start: start, end: end)
        }

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw OrpheusError.readerSetupFailed }
        reader.add(output)
        guard reader.startReading() else { throw OrpheusError.readerStartFailed(reader.error) }

        let state = rs
        readingQueue.async {
            state.assetReader  = reader
            state.readerOutput = output
        }
    }

    // MARK: - Progress timer

    private func startProgressTimer() {
        stopProgressTimer()
        let node    = playerNode
        let timer   = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick(node: node) }
        timer.resume()
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func tick(node: AVAudioPlayerNode) {
        guard isPlaying,
              let nodeTime   = node.lastRenderTime,
              let playerTime = node.playerTime(forHostTime: nodeTime.hostTime),
              playerTime.sampleTime >= 0 else { return }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = min(duration, seekOffset + elapsed)
        onTimeUpdate?(currentTime)
    }
}

// MARK: - Static buffer loop (no self capture, no actor isolation issues)

private enum OPEBufferLoop {

    static let preloadTarget: Int = OrpheusPlaybackEngine.preloadFrames
    private static let maxBuffers: Int = OrpheusPlaybackEngine.maxScheduledBuffers

    /// Fills the AVAudioPlayerNode buffer queue from `state.assetReader`.
    /// Must be called from readingQueue.
    static func feed(
        state:         OPEReaderState,
        node:          AVAudioPlayerNode,
        format:        AVAudioFormat,
        gen:           Int,
        onStart:       @escaping () -> Void,
        onEnd:         @escaping () -> Void,
        onError:       @escaping (String) -> Void,
        preloadTarget: Int
    ) {
        var framesScheduled = 0

        while state.scheduledBufferCount < maxBuffers && !state.isEOS {
            guard state.generation == gen,
                  let reader = state.assetReader, reader.status == .reading,
                  let output = state.readerOutput else {
                state.isEOS = true
                break
            }

            guard let sb = output.copyNextSampleBuffer() else {
                state.isEOS = true
                break
            }

            guard let pcm = convertToPCM(sb, format: format) else { continue }

            framesScheduled += Int(pcm.frameLength)
            state.scheduledBufferCount += 1

            node.scheduleBuffer(pcm) {
                guard state.generation == gen else { return }
                state.scheduledBufferCount = max(0, state.scheduledBufferCount - 1)

                let eos = state.isEOS
                let remaining = state.scheduledBufferCount

                if eos && remaining == 0 {
                    onEnd()
                } else if !eos {
                    // Feed needs to run on our dedicated queue, not the audio thread.
                    DispatchQueue.global(qos: .userInitiated).async {
                        OPEBufferLoop.feed(
                            state:         state,
                            node:          node,
                            format:        format,
                            gen:           gen,
                            onStart:       {},     // player already started
                            onEnd:         onEnd,
                            onError:       onError,
                            preloadTarget: 0       // no pre-load wait after initial start
                        )
                    }
                }
            }
        }

        // Start the node once we have enough pre-buffered frames (or hit EOS on a short track).
        let hasEnough = framesScheduled >= preloadTarget || state.isEOS
        if preloadTarget > 0 && hasEnough && state.scheduledBufferCount > 0 {
            node.play()
            onStart()
        } else if preloadTarget > 0 && state.isEOS && state.scheduledBufferCount == 0 {
            onEnd()
        }
    }

    // MARK: PCM conversion (called from readingQueue / background)

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

        let p = src.assumingMemoryBound(to: Float.self)
        let ch = Int(format.channelCount)
        if ch >= 2 {
            for i in 0..<Int(fc) {
                chL[i] = p[i * ch]
                chR[i] = p[i * ch + 1]
            }
        } else {
            // Mono source upmixed to stereo
            for i in 0..<Int(fc) { chL[i] = p[i]; chR[i] = p[i] }
        }
        _ = blk
        return buf
    }
}

// MARK: - Errors

enum OrpheusError: LocalizedError {
    case invalidDuration
    case noAudioTrack
    case assetLoadFailed(Error)
    case readerCreationFailed(Error)
    case readerSetupFailed
    case readerStartFailed(Error?)
    case formatSetupFailed

    var errorDescription: String? {
        switch self {
        case .invalidDuration:              return "Audio asset has no finite duration — may be a live/infinite stream"
        case .noAudioTrack:                 return "No audio track found in asset"
        case .assetLoadFailed(let e):       return "Asset load failed: \(e.localizedDescription)"
        case .readerCreationFailed(let e):  return "AVAssetReader creation failed: \(e.localizedDescription)"
        case .readerSetupFailed:            return "Cannot configure AVAssetReader output"
        case .readerStartFailed(let e):     return "AVAssetReader.startReading() failed: \(e?.localizedDescription ?? "unknown")"
        case .formatSetupFailed:            return "Failed to create AVAudioFormat for PCM output"
        }
    }
}
