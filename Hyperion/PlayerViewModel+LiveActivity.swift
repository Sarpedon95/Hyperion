#if canImport(ActivityKit)
import ActivityKit
import UIKit

// MARK: - Shared Activity Attributes (matches HyperionLiveActivity target)

struct HyperionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackTitle: String
        var artistName: String
        var albumTitle: String
        var isPlaying:  Bool
        var elapsed:    Double
        var duration:   Double
    }
    var albumArtData: Data?
}

// MARK: - PlayerViewModel Live Activity extension

extension PlayerViewModel {

    // MARK: - Live Activity management

    func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let track = currentTrack else { return }

        endLiveActivity()   // clear any existing activity first

        let artJPEG = artworkThumbnailJPEG()
        let attrs   = HyperionActivityAttributes(albumArtData: artJPEG)
        let state   = HyperionActivityAttributes.ContentState(
            trackTitle: track.title,
            artistName: track.albumartist ?? track.trackartist ?? track.composer ?? "",
            albumTitle: track.album ?? "",
            isPlaying:  isPlaying,
            elapsed:    currentTime,
            duration:   duration > 0 ? duration : (track.duration ?? 0)
        )

        do {
            let activity = try Activity<HyperionActivityAttributes>.request(
                attributes: attrs,
                content:    .init(state: state, staleDate: Date(timeIntervalSinceNow: 30))
            )
            _liveActivity = activity
        } catch {
            // Activities may be disabled or the entitlement missing — fail silently.
        }
    }

    func updateLiveActivity() {
        guard let activity = _liveActivity else { return }
        guard let track = currentTrack else { return }

        let state = HyperionActivityAttributes.ContentState(
            trackTitle: track.title,
            artistName: track.albumartist ?? track.trackartist ?? track.composer ?? "",
            albumTitle: track.album ?? "",
            isPlaying:  isPlaying,
            elapsed:    currentTime,
            duration:   duration > 0 ? duration : (track.duration ?? 0)
        )

        Task {
            await activity.update(
                .init(state: state, staleDate: Date(timeIntervalSinceNow: 30))
            )
        }
    }

    func endLiveActivity() {
        guard let activity = _liveActivity else { return }
        _liveActivity = nil
        Task {
            await activity.end(.none, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Artwork thumbnail

    private func artworkThumbnailJPEG() -> Data? {
        guard let coverid = currentTrack?.coverid, !coverid.isEmpty else { return nil }
        // Use a synchronous cache probe — we only want to include art that's already loaded.
        let cached = ArtworkCache.shared.cachedImage(coverid: coverid, targetPoints: 40, scale: 2)
        return cached?.jpegData(compressionQuality: 0.7)
    }
}

// MARK: - Stored activity reference (type-erased via Any? bridging on @MainActor class)

private var _liveActivityKey: UInt8 = 0

extension PlayerViewModel {
    // Use objc associated object to store the Activity without requiring Swift 5.9 generics
    // in a stored property on an @MainActor class (which would need nonisolated(unsafe)).
    // This is an internal implementation detail.
    fileprivate var _liveActivity: Activity<HyperionActivityAttributes>? {
        get { objc_getAssociatedObject(self, &_liveActivityKey) as? Activity<HyperionActivityAttributes> }
        set { objc_setAssociatedObject(self, &_liveActivityKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

#endif
