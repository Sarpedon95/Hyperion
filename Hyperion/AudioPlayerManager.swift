import AVFoundation
import Combine
import Foundation

/// Single long-lived owner for Hyperion's audio playback and DSP infrastructure.
///
/// AVPlayer handles HTTP streaming from LMS (seeking, KVO, buffering).
/// AVAudioEngine owns Orpheus DSP configuration nodes. Current playback is not
/// fed into those nodes, so the signal-path UI must not present Orpheus as
/// verified audio processing unless this routing flag changes.
/// Both are process-wide singletons; SwiftUI views must never own either directly.
@MainActor
final class AudioPlayerManager: ObservableObject {

    static let shared = AudioPlayerManager()

    // MARK: - Streaming path (AVPlayer)
    /// Kept for backward compat with all PlayerViewModel KVO / AVPlayerItem usage.
    let player: AVPlayer

    // MARK: - DSP signal chain (AVAudioEngine)
    /// Configured chain: playerNode → mainEQNode → headphoneEQNode → crossfeedMixer
    ///        → levelingMixer → balanceMixer → mainMixerNode → outputNode
    /// Important: AVPlayer output is not connected to `playerNode`; this graph is
    /// currently a configurable Orpheus engine, not the verified playback route.
    let isDSPChainFedByPlayback = false

    let engine          = AVAudioEngine()
    let playerNode      = AVAudioPlayerNode()
    let mainEQNode      = AVAudioUnitEQ(numberOfBands: 10)
    let headphoneEQNode = AVAudioUnitEQ(numberOfBands: 10)
    let crossfeedMixer  = AVAudioMixerNode()
    let levelingMixer   = AVAudioMixerNode()
    let balanceMixer    = AVAudioMixerNode()

    private init() {
        let persistentPlayer = AVPlayer()
        persistentPlayer.automaticallyWaitsToMinimizeStalling = true
        persistentPlayer.actionAtItemEnd = .pause
        player = persistentPlayer

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])

        buildDSPChain()
        ServerLogStore.shared.info("AudioPlayerManager initialized (AVPlayer direct stream; Orpheus AVAudioEngine configured separately)")
    }

    deinit {
        engine.stop()
        Task { @MainActor in
            ServerLogStore.shared.error("AudioPlayerManager deinit — audio lifetime was broken")
        }
    }

    // MARK: - DSP chain construction

    private func buildDSPChain() {
        engine.attach(playerNode)
        engine.attach(mainEQNode)
        engine.attach(headphoneEQNode)
        engine.attach(crossfeedMixer)
        engine.attach(levelingMixer)
        engine.attach(balanceMixer)

        // nil format → AVAudioEngine negotiates compatible format automatically.
        engine.connect(playerNode,      to: mainEQNode,            format: nil)
        engine.connect(mainEQNode,      to: headphoneEQNode,       format: nil)
        engine.connect(headphoneEQNode, to: crossfeedMixer,        format: nil)
        engine.connect(crossfeedMixer,  to: levelingMixer,         format: nil)
        engine.connect(levelingMixer,   to: balanceMixer,          format: nil)
        engine.connect(balanceMixer,    to: engine.mainMixerNode,  format: nil)

        engine.prepare()
        do {
            try engine.start()
            ServerLogStore.shared.info("AVAudioEngine DSP chain started successfully")
        } catch {
            ServerLogStore.shared.error("AVAudioEngine start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - PlayerViewModel compatibility surface

    func replaceCurrentItem(with item: AVPlayerItem?) {
        player.replaceCurrentItem(with: item)
    }

    func pause() {
        player.pause()
    }
}
