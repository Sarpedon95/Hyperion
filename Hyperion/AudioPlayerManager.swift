import AVFoundation
import Combine
import Foundation

/// Single long-lived owner for Hyperion's AVPlayer and playback audio session.
///
/// This object is intentionally a process-wide singleton. SwiftUI views and
/// navigation transitions must never own an AVPlayer directly; they should go
/// through PlayerViewModel, which uses this manager under the hood.
///
/// Audio session *category* is set here at init time so it is in place before
/// any AVPlayer operations. Session *activation* (`setActive(true)`) is owned
/// by PlayerViewModel, which calls it immediately before starting playback.
@MainActor
final class AudioPlayerManager: ObservableObject {

    static let shared = AudioPlayerManager()

    let player: AVPlayer

    private init() {
        // Create the AVPlayer first — configuring the audio session before
        // AVPlayer exists is unnecessary and can fail silently on background
        // launches (e.g. CarPlay cold start before the app is foregrounded).
        let persistentPlayer = AVPlayer()
        persistentPlayer.automaticallyWaitsToMinimizeStalling = true
        persistentPlayer.actionAtItemEnd = .pause
        player = persistentPlayer

        // Set the category (idempotent, never throws for .playback) so it is
        // ready the moment PlayerViewModel calls setActive(true). Do NOT call
        // setActive here — activation is deferred to the first play command.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])

        ServerLogStore.shared.info("AudioPlayerManager initialized with persistent AVPlayer")
    }

    deinit {
        Task { @MainActor in
            ServerLogStore.shared.error("AudioPlayerManager deinit — AVPlayer lifetime was broken")
        }
    }

    func replaceCurrentItem(with item: AVPlayerItem?) {
        player.replaceCurrentItem(with: item)
    }

    func pause() {
        player.pause()
    }
}
