import Foundation

/// Persists the full playback session (queue, position, shuffle, repeat) to
/// UserDefaults so the app can resume exactly where the user left off after
/// termination or a cold relaunch.
///
/// Design goals:
///  • Zero-cost reads: everything is loaded once into memory on init.
///  • Low-cost writes: encodes only when playback state actually changes;
///    debounced by 2 s so fast scrubbing doesn't thrash UserDefaults.
///  • Per-server keying: different LMS servers get independent slots so
///    switching servers never restores the wrong queue.
///  • Graceful degradation: any decode failure silently produces nil so the
///    caller just starts fresh without any visible error.
@MainActor
final class PlaybackStateStore {
    static let shared = PlaybackStateStore()

    // MARK: - Persisted snapshot

    struct Snapshot: Codable {
        let queue: [Track]
        let currentIndex: Int
        let currentTime: Double
        let isShuffle: Bool
        let repeatMode: Int
        let originalQueueBeforeShuffle: [Track]?
        let currentWorkGroupID: Int?
        let savedAt: Date
    }

    // MARK: - Private state

    // PERF: create encoder/decoder once.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Swift-concurrency-native debounce token. Unlike DispatchWorkItem, a Task
    // is explicitly @MainActor-aware: cancel() is safe to call from any context,
    // and the body captures self with full actor isolation so _writeSnapshot can
    // be called without hopping queues. This avoids the Swift 6 strict-concurrency
    // warning that DispatchWorkItem.asyncAfter produces when calling @MainActor
    // methods from within a non-isolated work item.
    private var saveTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    func saveNow(
        queue: [Track],
        currentIndex: Int,
        currentTime: Double,
        isShuffle: Bool,
        repeatMode: Int,
        originalQueueBeforeShuffle: [Track]?,
        currentWorkGroupID: Int?
    ) {
        saveTask?.cancel()
        saveTask = nil
        _writeSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            currentTime: currentTime,
            isShuffle: isShuffle,
            repeatMode: repeatMode,
            originalQueueBeforeShuffle: originalQueueBeforeShuffle,
            currentWorkGroupID: currentWorkGroupID
        )
    }

    /// Schedules a debounced save. Multiple calls within `delay` seconds are coalesced.
    func scheduleSave(
        queue: [Track],
        currentIndex: Int,
        currentTime: Double,
        isShuffle: Bool,
        repeatMode: Int,
        originalQueueBeforeShuffle: [Track]?,
        currentWorkGroupID: Int?,
        delay: TimeInterval = 2.0
    ) {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            // Swift-native debounce: Task.sleep respects cooperative cancellation,
            // so any call to saveTask?.cancel() cleanly aborts the pending save.
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self._writeSnapshot(
                queue: queue,
                currentIndex: currentIndex,
                currentTime: currentTime,
                isShuffle: isShuffle,
                repeatMode: repeatMode,
                originalQueueBeforeShuffle: originalQueueBeforeShuffle,
                currentWorkGroupID: currentWorkGroupID
            )
        }
    }

    /// Removes the saved snapshot — call after clearQueue() so a cold relaunch starts fresh.
    func clear() {
        saveTask?.cancel()
        saveTask = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Drops any pending debounced save without writing.
    /// Called when the server URL changes so a stale snapshot isn't saved under the new server's key.
    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    // MARK: - Private helpers

    private func _writeSnapshot(
        queue: [Track],
        currentIndex: Int,
        currentTime: Double,
        isShuffle: Bool,
        repeatMode: Int,
        originalQueueBeforeShuffle: [Track]?,
        currentWorkGroupID: Int?
    ) {
        guard !queue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        let snapshot = Snapshot(
            queue: queue,
            currentIndex: max(0, min(currentIndex, queue.count - 1)),
            currentTime: max(0, currentTime),
            isShuffle: isShuffle,
            repeatMode: repeatMode,
            originalQueueBeforeShuffle: originalQueueBeforeShuffle,
            currentWorkGroupID: currentWorkGroupID,
            savedAt: Date()
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private var storageKey: String {
        let server = LyrionAPI.shared.baseURL.isEmpty ? "default" : LyrionAPI.shared.baseURL
        let encoded = server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "default"
        return "com.hyperion.playbackState.v1.\(encoded)"
    }
}
