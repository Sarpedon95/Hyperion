import Foundation

/// Single entry point for resolving classical metadata for a track.
/// No other code calls LyrionAPI's classical-tag methods directly —
/// going through the resolver guarantees the in-memory cache stays
/// authoritative across views, the queue, and prefetch tasks.
@MainActor
final class ClassicalMetadataResolver: ObservableObject {
    static let shared = ClassicalMetadataResolver()

    private var cache: [Int: ClassicalMetadata] = [:]

    private init() {}

    /// Returns cached metadata if present, otherwise fetches both sources and
    /// stores the result. Returns nil when LyrionAPI cannot resolve anything.
    func resolve(trackID: Int) async -> ClassicalMetadata? {
        if let cached = cache[trackID] { return cached }

        let metadata = await LyrionAPI.shared.fetchClassicalMetadata(for: trackID)
        if let metadata { cache[trackID] = metadata }
        return metadata
    }

    /// Warms the cache for upcoming queue items. Runs sequentially with a
    /// small inter-fetch sleep so the server isn't hit with a burst right
    /// after the user changes tracks.
    func prefetch(trackIDs: [Int]) async {
        for id in trackIDs where cache[id] == nil {
            _ = await resolve(trackID: id)
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }
    }

    func invalidate(trackID: Int) {
        cache.removeValue(forKey: trackID)
    }

    func clearCache() {
        cache.removeAll()
    }
}
