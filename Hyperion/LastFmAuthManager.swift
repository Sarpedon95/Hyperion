import CryptoKit
import Foundation

// MARK: - Last.fm Auth + Scrobbling

@MainActor
final class LastFmAuthManager: ObservableObject {

    static let shared = LastFmAuthManager()

    @Published private(set) var username: String?   = nil
    @Published private(set) var sessionKey: String? = nil
    @Published var isAuthenticating: Bool = false
    @Published var authError: String?     = nil

    var isSignedIn: Bool { sessionKey != nil }

    private static let keySession  = "lastfm.sessionKey"
    private static let keyUsername = "lastfm.username"

    private let apiKey       = SecretsProvider.lastFmApiKey
    private let sharedSecret = SecretsProvider.lastFmSharedSecret

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    // MARK: Offline scrobble queue

    private struct PendingScrobble: Codable {
        let params: [String: String]
        var retryCount: Int
    }
    private var pendingScrobbles: [PendingScrobble] = []
    private var retryTask: Task<Void, Never>?

    private init() {
        sessionKey = KeychainManager.shared.load(key: Self.keySession)
        username   = KeychainManager.shared.load(key: Self.keyUsername)
    }

    // MARK: - Authentication

    func signIn(username: String, password: String) async {
        guard !username.isEmpty, !password.isEmpty else {
            authError = "Username and password are required."
            return
        }
        isAuthenticating = true
        authError = nil

        // auth.getMobileSession: authToken = md5(lowercase_username + md5(password))
        let pwMD5   = md5(password)
        let token   = md5(username.lowercased() + pwMD5)

        var params: [String: String] = [
            "method":    "auth.getMobileSession",
            "username":  username,
            "authToken": token,
            "api_key":   apiKey
        ]
        params["api_sig"] = apiSignature(params)
        params["format"]  = "json"

        do {
            let data = try await post(params: params)
            if let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sess    = json["session"] as? [String: Any],
               let key     = sess["key"]  as? String,
               let name    = sess["name"] as? String {
                self.sessionKey = key
                self.username   = name
                KeychainManager.shared.save(key: Self.keySession,  value: key)
                KeychainManager.shared.save(key: Self.keyUsername, value: name)
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg  = json["message"] as? String {
                authError = msg
            } else {
                authError = "Authentication failed. Check your username and password."
            }
        } catch {
            authError = "Network error: \(error.localizedDescription)"
        }
        isAuthenticating = false
    }

    func signOut() {
        sessionKey = nil
        username   = nil
        KeychainManager.shared.delete(key: Self.keySession)
        KeychainManager.shared.delete(key: Self.keyUsername)
    }

    // MARK: - Now Playing

    func updateNowPlaying(track: String, artist: String, album: String?, duration: Double?) {
        guard let sk = sessionKey, !sharedSecret.isEmpty else { return }
        var params: [String: String] = [
            "method":  "track.updateNowPlaying",
            "track":   track,
            "artist":  artist,
            "api_key": apiKey,
            "sk":      sk
        ]
        if let album, !album.isEmpty { params["album"]    = album }
        if let dur = duration        { params["duration"] = String(Int(dur)) }
        params["api_sig"] = apiSignature(params)
        params["format"]  = "json"

        Task { _ = try? await post(params: params) }
    }

    // MARK: - Scrobble

    func scrobble(track: String, artist: String, album: String?,
                  timestamp: TimeInterval, duration: Double?) {
        guard let sk = sessionKey, !sharedSecret.isEmpty else { return }
        var params: [String: String] = [
            "method":    "track.scrobble",
            "track":     track,
            "artist":    artist,
            "timestamp": String(Int(timestamp)),
            "api_key":   apiKey,
            "sk":        sk
        ]
        if let album, !album.isEmpty { params["album"]    = album }
        if let dur = duration        { params["duration"] = String(Int(dur)) }
        params["api_sig"] = apiSignature(params)
        params["format"]  = "json"

        Task {
            do {
                _ = try await post(params: params)
            } catch {
                pendingScrobbles.append(PendingScrobble(params: params, retryCount: 0))
                scheduleRetry()
            }
        }
    }

    // MARK: - Love / Unlove

    func love(track: String, artist: String) {
        sendLoveUnlove(method: "track.love", track: track, artist: artist)
    }

    func unlove(track: String, artist: String) {
        sendLoveUnlove(method: "track.unlove", track: track, artist: artist)
    }

    private func sendLoveUnlove(method: String, track: String, artist: String) {
        guard let sk = sessionKey, !sharedSecret.isEmpty else { return }
        var params: [String: String] = [
            "method":  method,
            "track":   track,
            "artist":  artist,
            "api_key": apiKey,
            "sk":      sk
        ]
        params["api_sig"] = apiSignature(params)
        params["format"]  = "json"
        Task { _ = try? await post(params: params) }
    }

    // MARK: - Offline retry

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await self?.flushOfflineQueue()
            self?.retryTask = nil
        }
    }

    func flushOfflineQueue() async {
        guard !pendingScrobbles.isEmpty else { return }
        var remaining: [PendingScrobble] = []
        for item in pendingScrobbles {
            guard item.retryCount < 5 else { continue }
            do {
                _ = try await post(params: item.params)
            } catch {
                remaining.append(PendingScrobble(params: item.params, retryCount: item.retryCount + 1))
            }
        }
        pendingScrobbles = remaining
        if !pendingScrobbles.isEmpty { scheduleRetry() }
    }

    // MARK: - API signature (Last.fm method signing)

    private func apiSignature(_ params: [String: String]) -> String {
        let filtered = params.filter { $0.key != "format" && $0.key != "callback" }
        let str = filtered.sorted { $0.key < $1.key }
                          .map { "\($0.key)\($0.value)" }
                          .joined() + sharedSecret
        return md5(str)
    }

    // MARK: - Crypto

    private func md5(_ string: String) -> String {
        let data   = Data(string.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Networking

    private func post(params: [String: String]) async throws -> Data {
        guard let url = URL(string: "https://ws.audioscrobbler.com/2.0/") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { k, v -> String in
                let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
