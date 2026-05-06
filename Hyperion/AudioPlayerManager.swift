import AVFoundation
import Combine
import Foundation

/// Single long-lived owner for Hyperion's audio playback and DSP infrastructure.
///
/// Orpheus (AVAudioPlayerNode → AVAudioEngine DSP chain) is the primary playback
/// path. OrpheusPlaybackEngine decodes LMS HTTP streams as PCM and schedules buffers
/// into `playerNode`, which feeds the full DSP graph. AVPlayer is retained as a
/// compatibility fallback (AirPlay, load failures, unsupported formats).
///
/// Both are process-wide singletons; SwiftUI views must never own either directly.
/// Routing truth is in PlayerViewModel.isPlaybackRoutedThroughOrpheus, not here.
@MainActor
final class AudioPlayerManager: ObservableObject {

    static let shared = AudioPlayerManager()

    // MARK: - Compatibility fallback (AVQueuePlayer)
    /// Used only when OrpheusPlaybackEngine cannot take the stream (AirPlay,
    /// load failure, unsupported format). Not connected to the DSP chain.
    /// AVQueuePlayer enables gapless playback by pre-inserting the next item
    /// before the current one ends; the player auto-advances with no silence gap.
    let player: AVQueuePlayer

    // MARK: - DSP signal chain (AVAudioEngine)
    /// Primary path: playerNode → mainEQNode → headphoneEQNode → crossfeedMixer
    ///        → levelingMixer → balanceMixer → mainMixerNode → outputNode
    /// OrpheusPlaybackEngine schedules decoded PCM buffers into `playerNode`.
    /// When `PlayerViewModel.isPlaybackRoutedThroughOrpheus` is true, audio is
    /// confirmed to be flowing through this chain.
    let isDSPChainFedByPlayback = false  // legacy flag — routing truth is in PlayerViewModel

    let engine          = AVAudioEngine()
    let playerNode      = AVAudioPlayerNode()
    let mainEQNode      = AVAudioUnitEQ(numberOfBands: 10)
    let headphoneEQNode = AVAudioUnitEQ(numberOfBands: 10)
    let crossfeedMixer  = AVAudioMixerNode()
    let levelingMixer   = AVAudioMixerNode()
    let balanceMixer    = AVAudioMixerNode()

    private init() {
        let persistentPlayer = AVQueuePlayer()
        persistentPlayer.automaticallyWaitsToMinimizeStalling = true
        // Do NOT set actionAtItemEnd to .pause — leave the default (.advance) so
        // pre-inserted items play back-to-back without a silence gap (gapless).
        player = persistentPlayer

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])

        buildDSPChain()
        ServerLogStore.shared.info("AudioPlayerManager initialized (Orpheus primary: PCM → AVAudioEngine DSP chain; AVPlayer retained as compatibility fallback)")
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

    /// Replace the entire queue with a single item. Removes all pre-queued
    /// gapless items so the player starts fresh on the new track.
    func replaceCurrentItem(with item: AVPlayerItem?) {
        player.removeAllItems()
        if let item { player.insert(item, after: nil) }
    }

    /// Pre-insert the next item at the tail of the queue so AVQueuePlayer can
    /// advance to it without a silence gap when the current item ends.
    func preloadNextItem(_ item: AVPlayerItem) {
        guard !player.items().contains(item) else { return }
        player.insert(item, after: player.items().last)
    }

    /// Remove all queued items except the currently playing one.
    /// Called when the queue changes so stale pre-loaded items don't play.
    func removePreloadedItems() {
        let items = player.items()
        guard items.count > 1 else { return }
        for item in items.dropFirst() { player.remove(item) }
    }

    func pause() {
        player.pause()
    }
}
