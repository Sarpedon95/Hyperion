// UserSession.swift
// Hyperion — Device owner / admin flag.
//
// Streaming integrations (Deezer ARL, Qobuz token + userID) hold credentials
// that belong to a specific account holder. The "admin" gate keeps every
// streaming-related code path — UI, search, keychain seed, playback router —
// dormant for any device that isn't the owner's. The flag defaults to true
// on first launch because Hyperion is a single-user app installed on the
// owner's own device; flipping it off is the explicit opt-out path.

import Foundation

final class UserSession {

    static let shared = UserSession()
    private init() {}

    private let adminKey = "hyperion.user.isAdmin"

    var isAdmin: Bool {
        get {
            UserDefaults.standard.object(forKey: adminKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: adminKey)
        }
    }
}
