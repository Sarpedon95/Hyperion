// PlaybackRouter.swift
// Hyperion — Streaming Playback Router
// Admin only — picks best available source for a track

import Foundation

final class PlaybackRouter {

    static let shared = PlaybackRouter()
    private init() {}

    // Priority order stored in UserDefaults — admin can reorder in Control Room
    @UserDefault(key: "playback.sourcePriority", defaultValue: ["local", "qobuz", "deezer"])
    var sourcePriority: [String]

    private var clients: [String: any StreamingSource] = [
        "qobuz": QobuzClient.shared,
        "deezer": DeezerClient.shared,
    ]

    // Resolve stream URL for a StreamTrack (from search/favorites)
    func resolveStreamURL(for track: StreamTrack) async throws -> URL {
        guard UserSession.shared.isAdmin else { throw StreamingError.adminRequired }

        for sourceKey in sourcePriority {
            switch sourceKey {
            case "qobuz" where track.source == .qobuz || track.isrc != nil:
                if let url = try? await QobuzClient.shared.getStreamURL(for: track) {
                    return url
                }
            case "deezer" where track.source == .deezer || track.isrc != nil:
                if let url = try? await DeezerClient.shared.getStreamURL(for: track) {
                    return url
                }
            default:
                continue
            }
        }
        throw StreamingError.noSourceAvailable
    }

    // For local LMS tracks — optionally find higher quality on Qobuz
    // Returns nil if local is already best or admin not available
    func resolveHigherQuality(
        artist: String,
        title: String,
        isrc: String?,
        localIsLossless: Bool
    ) async -> URL? {
        guard UserSession.shared.isAdmin, !localIsLossless else { return nil }

        // Try Qobuz by ISRC first (exact match), then title+artist
        let results: [StreamTrack]
        if let isrc {
            results = await QobuzClient.shared.search(query: isrc)
        } else {
            results = await QobuzClient.shared.search(query: "\(artist) \(title)")
        }

        guard let match = results.first(where: {
            $0.title.localizedCaseInsensitiveContains(title) &&
            $0.artist.localizedCaseInsensitiveContains(artist)
        }) else { return nil }

        return try? await QobuzClient.shared.getStreamURL(for: match)
    }
}

// MARK: - Keychain Seeder
// Seeds credentials on first admin launch. Never overwrites existing values.

enum StreamingKeychainSeeder {

    static func seedIfNeeded() {
        guard UserSession.shared.isAdmin else { return }

        let pairs: [(key: String, value: String)] = [
            ("deezer.arl",
             "3c546a21dea92d0f1debbe94d861bea1e43958ca375e2ab6a60f61927e312c692b1b78815d365dae2c2404ac8cdf319f0ea7f37bdb0369452c119697329557ba93227b4c73384d25d6c8dee2cc02751267cfe62e97ddde2a9d996a57a0a4281c"),
            ("qobuz.token",
             "Jc0Rq-RfQx98Dh-zxeqoBdnKmxngXUmZgsUkX_5D944yie5X9PTs4nhuAb8y3QdKm9s9T8H1P1Acq3fTWozFkA"),
            ("qobuz.userID",
             "7697609"),
        ]

        for pair in pairs {
            if KeychainManager.shared.load(key: pair.key) == nil {
                KeychainManager.shared.save(key: pair.key, value: pair.value)
            }
        }
    }
}

// MARK: - UserDefault property wrapper (if not already in project)

@propertyWrapper
struct UserDefault<T: Codable> {
    let key: String
    let defaultValue: T

    var wrappedValue: T {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(T.self, from: data) else {
                return defaultValue
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}
