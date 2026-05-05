import Foundation

enum SleepTimerMode: Hashable {
    case endOfTrack
    case minutes(Int)

    var displayName: String {
        switch self {
        case .endOfTrack:      return "End of track"
        case .minutes(let m):  return "\(m) min"
        }
    }
}

@MainActor
final class SleepTimerManager: ObservableObject {
    static let shared = SleepTimerManager()

    static let minuteOptions = [5, 10, 15, 30, 45, 60]

    @Published private(set) var isActive: Bool = false
    @Published private(set) var timeRemaining: TimeInterval = 0
    @Published private(set) var mode: SleepTimerMode = .minutes(30)

    private var fireAt: Date?
    private var timer: DispatchSourceTimer?

    private init() {}

    func set(mode: SleepTimerMode) {
        cancel()
        self.mode = mode
        isActive  = true

        switch mode {
        case .endOfTrack:
            timeRemaining = 0
        case .minutes(let m):
            let interval  = TimeInterval(m * 60)
            timeRemaining = interval
            fireAt        = Date().addingTimeInterval(interval)
            startTicking()
        }
    }

    func cancel() {
        isActive      = false
        timeRemaining = 0
        fireAt        = nil
        stopTicking()
    }

    /// Called by PlayerViewModel.trackDidFinish(). Returns true and pauses playback
    /// when the sleep timer is set to end-of-track mode; false otherwise.
    func consumeEndOfTrackTrigger() -> Bool {
        guard isActive, case .endOfTrack = mode else { return false }
        cancel()
        return true
    }

    // MARK: - Private

    private func startTicking() {
        stopTicking()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTicking() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let fireAt else { return }
        let remaining = fireAt.timeIntervalSinceNow
        if remaining <= 0 {
            cancel()
            PlayerViewModel.shared.pause()
        } else {
            timeRemaining = remaining
        }
    }
}
