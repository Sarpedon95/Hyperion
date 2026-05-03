import AVFoundation
import Combine
import Foundation

/// Single long-lived owner for Hyperion's AVPlayer and playback audio session.
///
/// This object is intentionally a process-wide singleton. SwiftUI views and
/// navigation transitions must never own an AVPlayer directly; they should go
/// through PlayerViewModel, which uses this manager under the hood.
@MainActor
final class AudioPlayerManager: ObservableObject {

    static let shared = AudioPlayerManager()

    let player: AVPlayer

    private init() {
        // Configure and activate the session before creating AVPlayer. This is
        // the critical ordering for lock-screen/background handoff reliability.
        Self.configureAudioSession(reason: "manager-init")

        let persistentPlayer = AVPlayer()
        persistentPlayer.automaticallyWaitsToMinimizeStalling = true
        persistentPlayer.actionAtItemEnd = .pause
        player = persistentPlayer

        ServerLogStore.shared.info("AudioPlayerManager initialized with persistent AVPlayer")
    }

    deinit {
        Task { @MainActor in
            ServerLogStore.shared.error("AudioPlayerManager deinit — AVPlayer lifetime was broken")
        }
    }

    @discardableResult
    func configureAudioSession(reason: String = "explicit") -> Bool {
        Self.configureAudioSession(reason: reason)
    }

    @discardableResult
    private static func configureAudioSession(reason: String) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
            ServerLogStore.shared.debug("Audio session configured for playback (reason=\(reason), category=\(session.category.rawValue), mode=\(session.mode.rawValue))")
            return true
        } catch {
            ServerLogStore.shared.error("Audio session configuration failed (reason=\(reason)): \(error.localizedDescription)")
            return false
        }
    }

    func play(url: URL) {
        let item = AVPlayerItem(url: url)
        replaceCurrentItem(with: item)
        player.play()
    }

    func replaceCurrentItem(with item: AVPlayerItem?) {
        player.replaceCurrentItem(with: item)
    }

    func pause() {
        player.pause()
    }
}
