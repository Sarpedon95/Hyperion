import Foundation

// AUDIT-FIX #4 — credentials stored in Keychain, not embedded in the URL string.
// Migration: if the URL still contains user:pass@ on load, the credentials are
// extracted, saved to Keychain, and stripped from the stored URL automatically.
enum HyperionURLAuth {

    // MARK: - Keychain keys
    private static let usernameKey = "lms.credentials.username"
    private static let passwordKey = "lms.credentials.password"

    // MARK: - Credential Keychain access

    static func saveCredentials(username: String, password: String) {
        if username.isEmpty {
            KeychainManager.shared.delete(key: usernameKey)
            KeychainManager.shared.delete(key: passwordKey)
        } else {
            KeychainManager.shared.save(key: usernameKey, value: username)
            KeychainManager.shared.save(key: passwordKey, value: password)
        }
    }

    static func loadCredentials() -> (username: String, password: String)? {
        guard let u = KeychainManager.shared.load(key: usernameKey), !u.isEmpty else { return nil }
        return (u, KeychainManager.shared.load(key: passwordKey) ?? "")
    }

    /// Strips embedded user:pass from a URL and returns the bare URL string.
    /// Call this before persisting URLs to UserDefaults.
    static func stripCredentials(from rawURL: String) -> String {
        guard var comps = URLComponents(string: rawURL),
              comps.user != nil else { return rawURL }
        comps.user = nil
        comps.password = nil
        return comps.string ?? rawURL
    }

    /// If the URL has embedded credentials, migrate them to Keychain and return the bare URL.
    static func migrateCredentials(from rawURL: String) -> String {
        guard var comps = URLComponents(string: rawURL),
              let user = comps.user, !user.isEmpty else { return rawURL }
        let password = comps.password ?? ""
        saveCredentials(username: user, password: password)
        comps.user = nil
        comps.password = nil
        return comps.string ?? rawURL
    }

    // MARK: - Authorization header construction

    static func authorizationHeader(from rawURL: String) -> String? {
        // Prefer Keychain credentials; fall back to URL-embedded creds for compat.
        if let creds = loadCredentials() {
            let token = "\(creds.username):\(creds.password)"
            guard let data = token.data(using: .utf8) else { return nil }
            return "Basic \(data.base64EncodedString())"
        }
        guard let url = URL(string: rawURL) else { return nil }
        return authorizationHeader(from: url)
    }

    static func authorizationHeader(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let user = components.user,
              !user.isEmpty else {
            return nil
        }
        let password = components.password ?? ""
        let token = "\(user):\(password)"
        guard let data = token.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    static func addAuthorizationHeader(to request: inout URLRequest, baseURL: String) {
        guard let header = authorizationHeader(from: baseURL) else { return }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }
}
