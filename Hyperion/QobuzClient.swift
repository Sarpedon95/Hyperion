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
    // Tries 24bit FLAC first, then 16bit FLAC, then MP3 320

    func getStreamURL(for track: StreamTrack) async throws -> URL {
        for formatID in ["27", "6", "5"] {
            if let url = try? await fetchFileURL(trackID: track.id, formatID: formatID) {
                return url
            }
        }
        throw StreamingError.trackNotFound
    }

    private func fetchFileURL(trackID: String, formatID: String) async throws -> URL {
        guard let secret = appSecret, !secret.isEmpty else {
            log("getFileUrl: missing qobuz.secret in Keychain — cannot sign request")
            throw StreamingError.authenticationFailed
        }

        // Qobuz signs getFileUrl: md5 of the method + the request params in
        // alphabetical order (key+value concatenated, no separators) + a unix
        // timestamp + the app secret.
        let intent = "stream"
        let ts  = String(Int(Date().timeIntervalSince1970))
        let sig = md5Hex("trackgetFileUrlformat_id\(formatID)intent\(intent)track_id\(trackID)\(ts)\(secret)")

        guard let data = await get("/track/getFileUrl",
                                   params: ["track_id":   trackID,
                                            "format_id":   formatID,
                                            "intent":      intent,
                                            "request_ts":  ts,
                                            "request_sig": sig]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamingError.trackNotFound
        }
        if let urlString = json["url"] as? String, let url = URL(string: urlString) {
            return url
        }
        log("getFileUrl fmt \(formatID): \(json["message"] as? String ?? "no url in response")")
        throw StreamingError.trackNotFound
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
