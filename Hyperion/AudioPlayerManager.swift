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
    /// Primary path (once crossfeed AU loads):
    ///   playerNode → mainEQNode → headphoneEQNode → crossfeedUnit
    ///              → levelingMixer → balanceMixer → mainMixerNode → outputNode
    ///
    /// Before the crossfeed AU is available (initial boot):
    ///   playerNode → mainEQNode → headphoneEQNode → crossfeedMixer (pass-through)
    ///              → levelingMixer → balanceMixer → mainMixerNode → outputNode
    let isDSPChainFedByPlayback = false  // legacy flag — routing truth is in PlayerViewModel

    let engine          = AVAudioEngine()
    let playerNode      = AVAudioPlayerNode()
    let mainEQNode      = AVAudioUnitEQ(numberOfBands: 10)
    let headphoneEQNode = AVAudioUnitEQ(numberOfBands: 10)
    let levelingMixer   = AVAudioMixerNode()
    let balanceMixer    = AVAudioMixerNode()

    // crossfeedMixer is the pass-through placeholder until the real AU loads.
    let crossfeedMixer  = AVAudioMixerNode()

    // The real Bauer crossfeed AU. Set once after async instantiation.
    private(set) var crossfeedUnit: AVAudioUnit?
    // Typed accessor into the AU's DSP parameters.
    private(set) var crossfeedAU: CrossfeedAudioUnit?

    private init() {
        let persistentPlayer = AVQueuePlayer()
        persistentPlayer.automaticallyWaitsToMinimizeStalling = true
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

        // Initial chain uses crossfeedMixer as a pass-through placeholder.
        engine.connect(playerNode,      to: mainEQNode,           format: nil)
        engine.connect(mainEQNode,      to: headphoneEQNode,      format: nil)
        engine.connect(headphoneEQNode, to: crossfeedMixer,       format: nil)
        engine.connect(crossfeedMixer,  to: levelingMixer,        format: nil)
        engine.connect(levelingMixer,   to: balanceMixer,         format: nil)
        engine.connect(balanceMixer,    to: engine.mainMixerNode, format: nil)

        engine.prepare()
        do {
            try engine.start()
            ServerLogStore.shared.info("AVAudioEngine DSP chain started successfully")
        } catch {
            ServerLogStore.shared.error("AVAudioEngine start failed: \(error.localizedDescription)")
        }

        // Load the real crossfeed AU asynchronously and splice it in.
        Task { await loadCrossfeedAU() }
    }

    // MARK: - Crossfeed AU hot-splice

    private func loadCrossfeedAU() async {
        let unit: AVAudioUnit? = await withCheckedContinuation { continuation in
            AVAudioUnit.instantiate(
                with: CrossfeedAudioUnit.componentDescription,
                options: []
            ) { avUnit, _ in
                continuation.resume(returning: avUnit)
            }
        }

        guard let unit, let au = unit.auAudioUnit as? CrossfeedAudioUnit else {
            ServerLogStore.shared.info("CrossfeedAudioUnit: instantiation failed, using pass-through mixer")
            return
        }

        // Splice the real AU into the chain between headphoneEQNode and levelingMixer.
        // The engine is paused briefly; no audio is playing during boot so no audible gap.
        engine.pause()
        engine.disconnectNodeOutput(headphoneEQNode)
        engine.disconnectNodeOutput(crossfeedMixer)
        engine.detach(crossfeedMixer)
        engine.attach(unit)
        engine.connect(headphoneEQNode, to: unit,            format: nil)
        engine.connect(unit,            to: levelingMixer,   format: nil)
        try? engine.start()

        crossfeedUnit = unit
        crossfeedAU   = au
        ServerLogStore.shared.info("CrossfeedAudioUnit: Bauer crossfeed DSP loaded and spliced into chain")

        // Apply current DSP settings now that the real AU is available.
        OrpheusDSPEngine.shared.applyCrossfeed()
    }

    // MARK: - PlayerViewModel compatibility surface

    func replaceCurrentItem(with item: AVPlayerItem?) {
        player.removeAllItems()
        if let item { player.insert(item, after: nil) }
    }

    func preloadNextItem(_ item: AVPlayerItem) {
        guard !player.items().contains(item) else { return }
        player.insert(item, after: player.items().last)
    }

    func removePreloadedItems() {
        let items = player.items()
        guard items.count > 1 else { return }
        for item in items.dropFirst() { player.remove(item) }
    }

    func pause() {
        player.pause()
    }
}
