// QobuzClient.swift
// Hyperion — Qobuz Streaming Integration
// Personal use only

import Foundation
import CryptoKit

final class QobuzClient: StreamingSource {

    static let shared = QobuzClient()
    private init() {}

    let name = "Qobuz"
    let sourceType: StreamSourceType = .qobuz

    private func log(_ s: String) {
        Task { @MainActor in ServerLogStore.shared.debug("[Qobuz] \(s)") }
    }

    // MARK: - Credentials (from Keychain)

    private var userAuthToken: String? {
        KeychainManager.shared.load(key: "qobuz.token")
    }
    private var userID: String? {
        KeychainManager.shared.load(key: "qobuz.userID")
    }
    // App secret paired with `appID`. Required to sign /track/getFileUrl requests.
    // Qobuz rotates app_id/secret pairs, so this lives in Keychain rather than
    // being hardcoded.
    private var appSecret: String? {
        KeychainManager.shared.load(key: "qobuz.secret")
    }

    // Standard mobile app_id used by open source clients
    private let appID = "285473059"
    private let apiBase = "https://www.qobuz.com/api.json/0.2"

    var isAvailable: Bool {
        get async { userAuthToken != nil }
    }

    // MARK: - Request helper

    private func get(_ path: String, params: [String: String] = [:]) async -> Data? {
        guard let token = userAuthToken else {
            log("request \(path) skipped — no Qobuz token in Keychain")
            return nil
        }
        var all = params
        all["app_id"] = appID
        var comps = URLComponents(string: apiBase + path)!
        comps.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.setValue(token, forHTTPHeaderField: "X-User-Auth-Token")
        req.setValue(appID, forHTTPHeaderField: "X-App-Id")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 {
                let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
                log("request \(path): HTTP \(code) \(body)")
            }
            return data
        } catch {
            log("request \(path): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Search

    func search(query: String) async -> [StreamTrack] {
        guard !query.isEmpty else { return [] }
        guard let data = await get("/catalog/search",
                                   params: ["query": query, "limit": "30", "type": "tracks"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]] else {
            log("search '\(query)': 0 tracks (see request log above)")
            return []
        }
        let parsed = items.compactMap { parseQobuzTrack($0) }
        log("search '\(query)': \(items.count) raw → \(parsed.count) tracks")
        return parsed
    }

    func searchAlbums(query: String) async -> [StreamAlbum] {
        guard !query.isEmpty else { return [] }
        guard let data = await get("/catalog/search",
                                   params: ["query": query, "limit": "20", "type": "albums"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let albums = json["albums"] as? [String: Any],
              let items = albums["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseQobuzAlbum($0) }
    }

    // MARK: - Album

    func getAlbum(id: String) async throws -> StreamAlbum {
        guard let data = await get("/album/get", params: ["album_id": id]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let album = parseQobuzAlbum(json) else { throw StreamingError.trackNotFound }
        return album
    }

    func getAlbumTracks(albumID: String) async -> [StreamTrack] {
        guard let data = await get("/album/get", params: ["album_id": albumID]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]] else { return [] }
        // Album context for artwork
        let artworkURL = (json["image"] as? [String: Any])
            .flatMap { ($0["large"] as? String).flatMap { URL(string: $0) } }
        let albumTitle = json["title"] as? String ?? ""
        let albumArtist = (json["artist"] as? [String: Any])?["name"] as? String ?? ""
        return items.compactMap { parseQobuzTrack($0,
                                                   albumTitle: albumTitle,
                                                   albumArtist: albumArtist,
                                                   artworkURL: artworkURL) }
    }

    // MARK: - Favorites

    func getUserFavorites() async -> [StreamTrack] {
        guard let uid = userID else { return [] }
        guard let data = await get("/favorite/getUserFavorites",
                                   params: ["type": "tracks", "limit": "500", "user_id": uid]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseQobuzTrack($0) }
    }

    func getUserFavoriteAlbums() async -> [StreamAlbum] {
        guard let uid = userID else { return [] }
        guard let data = await get("/favorite/getUserFavorites",
                                   params: ["type": "albums", "limit": "200", "user_id": uid]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let albums = json["albums"] as? [String: Any],
              let items = albums["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseQobuzAlbum($0) }
    }

    // MARK: - Stream URL
    //
    // Qobuz signs /track/getFileUrl with an app secret that is NOT a per-user
    // credential — it is baked into the Qobuz web player. We derive it (and the
    // app_id) from the public web bundle on first use and cache the working pair
    // in Keychain, so the user only ever supplies a token + user ID. A manually
    // entered secret (Control Room) is tried as a fallback. Tries 24-bit FLAC,
    // then 16-bit FLAC, then MP3 320.

    func getStreamURL(for track: StreamTrack) async throws -> URL {
        guard userAuthToken != nil else {
            log("getStreamURL: no Qobuz token")
            throw StreamingError.authenticationFailed
        }
        let creds = await resolveSigningCredentials()
        guard !creds.secrets.isEmpty else {
            log("getStreamURL: no app secret (bundle derivation failed and none entered manually)")
            throw StreamingError.authenticationFailed
        }
        for formatID in ["27", "6", "5"] {
            for secret in creds.secrets {
                if let url = try? await fetchFileURL(trackID: track.id, formatID: formatID,
                                                     appID: creds.appID, secret: secret) {
                    // Remember the winning pair so later plays skip derivation.
                    KeychainManager.shared.save(key: "qobuz.appID",          value: creds.appID)
                    KeychainManager.shared.save(key: "qobuz.secretVerified", value: secret)
                    return url
                }
            }
        }
        throw StreamingError.trackNotFound
    }

    private func fetchFileURL(trackID: String, formatID: String, appID: String, secret: String) async throws -> URL {
        guard let token = userAuthToken else { throw StreamingError.authenticationFailed }

        // Signature = md5(method + params in alphabetical order, key+value with no
        // separators, + unix timestamp + app secret).
        let intent = "stream"
        let ts  = String(Int(Date().timeIntervalSince1970))
        let sig = md5Hex("trackgetFileUrlformat_id\(formatID)intent\(intent)track_id\(trackID)\(ts)\(secret)")

        var comps = URLComponents(string: apiBase + "/track/getFileUrl")!
        comps.queryItems = [
            URLQueryItem(name: "track_id",    value: trackID),
            URLQueryItem(name: "format_id",   value: formatID),
            URLQueryItem(name: "intent",      value: intent),
            URLQueryItem(name: "request_ts",  value: ts),
            URLQueryItem(name: "request_sig", value: sig),
            URLQueryItem(name: "app_id",      value: appID),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(token, forHTTPHeaderField: "X-User-Auth-Token")
        req.setValue(appID, forHTTPHeaderField: "X-App-Id")

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamingError.trackNotFound
        }
        if let urlString = json["url"] as? String, let url = URL(string: urlString) {
            return url
        }
        // Wrong secret → {"status":"error","code":400,"message":"Invalid Request Signature"}
        log("getFileUrl fmt \(formatID) HTTP \(code): \(json["message"] as? String ?? "no url")")
        throw StreamingError.trackNotFound
    }

    // MARK: - App credential resolution (app_id + signing secret)

    private var resolvedAppID: String {
        KeychainManager.shared.load(key: "qobuz.appID") ?? appID
    }

    private func resolveSigningCredentials() async -> (appID: String, secrets: [String]) {
        // 1. Previously verified pair (cached after a successful stream).
        if let id = KeychainManager.shared.load(key: "qobuz.appID"),
           let secret = KeychainManager.shared.load(key: "qobuz.secretVerified"), !secret.isEmpty {
            return (id, [secret])
        }
        // 2. Manual override first (if entered), then secrets derived from the bundle.
        var candidates: [String] = []
        if let manual = appSecret, !manual.isEmpty { candidates.append(manual) }
        var appID = resolvedAppID
        if let bundle = await fetchBundleCredentials() {
            appID = bundle.appID
            for s in bundle.secrets where !candidates.contains(s) { candidates.append(s) }
        }
        return (appID, candidates)
    }

    /// Scrape app_id + candidate signing secrets from the Qobuz web-player bundle.
    /// Mirrors the well-known seed/timezone derivation used by open-source clients.
    private func fetchBundleCredentials() async -> (appID: String, secrets: [String])? {
        guard let loginURL = URL(string: "https://play.qobuz.com/login"),
              let (loginData, _) = try? await URLSession.shared.data(from: loginURL),
              let html = String(data: loginData, encoding: .utf8) else {
            log("bundle: login page fetch failed"); return nil
        }
        guard let bundlePath = Self.firstGroup(in: html,
              pattern: #"<script src="(/resources/[\d.]+-[a-z]\d{3}/bundle\.js)">"#) else {
            log("bundle: bundle.js path not found"); return nil
        }
        guard let bundleURL = URL(string: "https://play.qobuz.com" + bundlePath),
              let (bundleData, _) = try? await URLSession.shared.data(from: bundleURL),
              let bundle = String(data: bundleData, encoding: .utf8) else {
            log("bundle: bundle.js fetch failed"); return nil
        }

        let appID = Self.firstGroup(in: bundle, pattern: #"production:\{api:\{appId:"(\d{9})""#) ?? resolvedAppID

        // Collect (timezone -> [seed]) pairs.
        var entries: [(tz: String, parts: [String])] = []
        for g in Self.allGroups(in: bundle,
              pattern: #"[a-z]\.initialSeed\("([\w=]+)",window\.utimezone\.([a-z]+)\)"#) where g.count >= 2 {
            entries.append((tz: g[1], parts: [g[0]]))
        }
        guard !entries.isEmpty else { log("bundle: no seeds found"); return (appID, []) }
        if entries.count >= 2 { entries.swapAt(0, 1) }   // ordering used by the reference impl

        // Append (info, extras) for the matching capitalized timezone names.
        let tzAlt = entries.map { $0.tz.prefix(1).uppercased() + $0.tz.dropFirst() }.joined(separator: "|")
        let iesPattern = #"name:"\w+/(\#(tzAlt))",info:"([\w=]+)",extras:"([\w=]+)""#
        for g in Self.allGroups(in: bundle, pattern: iesPattern) where g.count >= 3 {
            let tz = g[0].lowercased()
            if let i = entries.firstIndex(where: { $0.tz == tz }) {
                entries[i].parts.append(g[1])
                entries[i].parts.append(g[2])
            }
        }

        // secret = base64decode( join(seed, info, extras) with the last 44 chars dropped ).
        var secrets: [String] = []
        for e in entries {
            let joined = e.parts.joined()
            guard joined.count > 44 else { continue }
            if let secret = Self.base64Decoded(String(joined.dropLast(44))), !secret.isEmpty {
                secrets.append(secret)
            }
        }
        log("bundle: appID \(appID), \(secrets.count) secret candidate(s)")
        return (appID, secrets)
    }

    // MARK: - Regex / base64 helpers

    private static func firstGroup(in s: String, pattern: String) -> String? {
        allGroups(in: s, pattern: pattern).first?.first
    }

    private static func allGroups(in s: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: range).map { m in
            (1..<m.numberOfRanges).compactMap { idx -> String? in
                guard let r = Range(m.range(at: idx), in: s) else { return nil }
                return String(s[r])
            }
        }
    }

    private static func base64Decoded(_ s: String) -> String? {
        var padded = s
        let rem = padded.count % 4
        if rem > 0 { padded += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Quality label

    func qualityLabel(for track: StreamTrack) async -> String? {
        guard let data = await get("/track/get", params: ["track_id": track.id]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let bitDepth = json["maximum_bit_depth"] as? Int ?? 16
        let samplingRate = json["maximum_sampling_rate"] as? Double ?? 44.1
        if bitDepth >= 24 { return "\(bitDepth)bit / \(Int(samplingRate))kHz" }
        return "16bit / 44.1kHz"
    }

    // MARK: - Parsers

    private func parseQobuzTrack(
        _ d: [String: Any],
        albumTitle: String? = nil,
        albumArtist: String? = nil,
        artworkURL: URL? = nil
    ) -> StreamTrack? {
        guard let id = d["id"].map({ "\($0)" }),
              let title = d["title"] as? String else { return nil }

        let performer = (d["performer"] as? [String: Any])?["name"] as? String
                     ?? albumArtist ?? ""
        let albumDict = d["album"] as? [String: Any]
        let album = albumTitle ?? albumDict?["title"] as? String ?? ""
        let albumID = albumDict?["id"].map { "\($0)" } ?? ""
        let duration = d["duration"] as? TimeInterval ?? 0
        let artwork = artworkURL
            ?? (albumDict?["image"] as? [String: Any])
                .flatMap { ($0["large"] as? String).flatMap { URL(string: $0) } }
        let isrc = d["isrc"] as? String
        let composer = (d["composer"] as? [String: Any])?["name"] as? String
        let work = d["work"] as? String

        return StreamTrack(
            id: id, title: title, artist: performer,
            album: album, albumID: albumID, duration: duration,
            artworkURL: artwork, source: .qobuz, isrc: isrc,
            composer: composer, work: work, conductor: nil
        )
    }

    private func parseQobuzAlbum(_ d: [String: Any]) -> StreamAlbum? {
        guard let id = d["id"].map({ "\($0)" }),
              let title = d["title"] as? String else { return nil }

        let artist = (d["artist"] as? [String: Any])?["name"] as? String ?? ""
        let artwork = (d["image"] as? [String: Any])
            .flatMap { ($0["large"] as? String).flatMap { URL(string: $0) } }
        let year = (d["released_at"] as? TimeInterval).map {
            Calendar.current.component(.year, from: Date(timeIntervalSince1970: $0))
        }
        let trackCount = (d["tracks_count"] as? Int)

        return StreamAlbum(
            id: id, title: title, artist: artist,
            artworkURL: artwork, year: year,
            source: .qobuz, trackCount: trackCount
        )
    }
}
