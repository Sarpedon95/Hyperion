// DeezerClient.swift
// Hyperion — Deezer Streaming Integration
// Personal use only — uses ARL cookie authentication

import Foundation

final class DeezerClient: StreamingSource {

    static let shared = DeezerClient()
    private init() {}

    let name = "Deezer"
    let sourceType: StreamSourceType = .deezer

    private func log(_ s: String) {
        Task { @MainActor in ServerLogStore.shared.debug("[Deezer] \(s)") }
    }

    // MARK: - Keychain

    private var arl: String? {
        KeychainManager.shared.load(key: "deezer.arl")
    }

    var isAvailable: Bool {
        get async { arl != nil }
    }

    // MARK: - URL helpers

    private let apiBase = "https://api.deezer.com"
    private let gwBase  = "https://www.deezer.com/ajax/gw-light.php"

    private func apiURL(_ path: String, params: [String: String] = [:]) -> URL {
        var comps = URLComponents(string: apiBase + path)!
        if !params.isEmpty {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    private func arlCookie() -> String {
        "arl=\(arl ?? "")"
    }

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["Cookie": arlCookie()]
        return URLSession(configuration: cfg)
    }

    // MARK: - Search

    func search(query: String) async -> [StreamTrack] {
        guard !query.isEmpty else { return [] }
        let url = apiURL("/search", params: ["q": query, "limit": "30"])
        do {
            let (data, response) = try await session().data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("search '\(query)': HTTP \(code), response not JSON")
                return []
            }
            if let err = json["error"] as? [String: Any] {
                log("search '\(query)': API error \(err)")
                return []
            }
            guard let items = json["data"] as? [[String: Any]] else {
                log("search '\(query)': HTTP \(code), no 'data' array")
                return []
            }
            let tracks = items.compactMap { parseDeezerTrack($0) }
            log("search '\(query)': HTTP \(code), \(items.count) raw → \(tracks.count) tracks")
            return tracks
        } catch {
            log("search '\(query)': \(error.localizedDescription)")
            return []
        }
    }

    func searchAlbums(query: String) async -> [StreamAlbum] {
        guard !query.isEmpty else { return [] }
        let url = apiURL("/search/album", params: ["q": query, "limit": "20"])
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerAlbum($0) }
    }

    // MARK: - Album

    func getAlbum(id: String) async throws -> StreamAlbum {
        let url = apiURL("/album/\(id)")
        let data = try await session().data(from: url).0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let album = parseDeezerAlbum(json) else { throw StreamingError.trackNotFound }
        return album
    }

    func getAlbumTracks(albumID: String) async -> [StreamTrack] {
        let url = apiURL("/album/\(albumID)/tracks", params: ["limit": "100"])
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerTrack($0) }
    }

    // MARK: - Favorites

    func getUserFavorites() async -> [StreamTrack] {
        let url = apiURL("/user/me/tracks", params: ["limit": "500"])
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerTrack($0) }
    }

    func getUserFavoriteAlbums() async -> [StreamAlbum] {
        let url = apiURL("/user/me/albums", params: ["limit": "200"])
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerAlbum($0) }
    }

    // MARK: - Stream URL
    // Uses Deezer's internal gateway — same approach as deemix/streamrip for personal use

    func getStreamURL(for track: StreamTrack) async throws -> URL {
        guard let arl else {
            log("getStreamURL: no Deezer ARL in Keychain")
            throw StreamingError.authenticationFailed
        }

        // Step 1 — get user token
        let userToken = try await fetchUserToken(arl: arl)

        // Step 2 — get track token
        let trackToken = try await fetchTrackToken(trackID: track.id, userToken: userToken)

        // Step 3 — get signed media URL (FLAC preferred, MP3_320 fallback)
        let streamURL = try await fetchMediaURL(trackToken: trackToken, userToken: userToken)
        // NOTE: Deezer media streams are Blowfish-encrypted (BF_CBC_STRIPE). This
        // URL points at encrypted bytes — AVPlayer cannot play it directly without
        // an on-the-fly decryption layer. See getStreamURL callers / PlaybackRouter.
        log("getStreamURL: resolved encrypted media URL for track \(track.id) — playback needs Blowfish decryption")

        return streamURL
    }

    private func fetchUserToken(arl: String) async throws -> String {
        var comps = URLComponents(string: gwBase)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "deezer.getUserData"),
            URLQueryItem(name: "api_version", value: "1.0"),
            URLQueryItem(name: "api_token", value: "null"),
            URLQueryItem(name: "input", value: "3"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("arl=\(arl)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let token = results["checkForm"] as? String else {
            throw StreamingError.authenticationFailed
        }
        return token
    }

    private func fetchTrackToken(trackID: String, userToken: String) async throws -> String {
        var comps = URLComponents(string: gwBase)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "song.getListData"),
            URLQueryItem(name: "api_version", value: "1.0"),
            URLQueryItem(name: "api_token", value: userToken),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("arl=\(arl ?? "")", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sng_ids": [trackID]])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let list = results["data"] as? [[String: Any]],
              let first = list.first,
              let token = first["TRACK_TOKEN"] as? String else {
            throw StreamingError.trackNotFound
        }
        return token
    }

    private func fetchMediaURL(trackToken: String, userToken: String) async throws -> URL {
        var comps = URLComponents(string: gwBase)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "media.getUrl"),
            URLQueryItem(name: "api_version", value: "1.0"),
            URLQueryItem(name: "api_token", value: userToken),
        ]
        let body: [String: Any] = [
            "license_token": trackToken,
            "media": [["type": "FULL", "formats": [
                ["cipher": "BF_CBC_STRIPE", "format": "FLAC"],
                ["cipher": "BF_CBC_STRIPE", "format": "MP3_320"],
                ["cipher": "BF_CBC_STRIPE", "format": "MP3_128"],
            ]]]
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("arl=\(arl ?? "")", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]],
              let first = results.first,
              let media = first["media"] as? [[String: Any]],
              let firstMedia = media.first,
              let sources = firstMedia["sources"] as? [[String: Any]],
              let firstSource = sources.first,
              let urlString = firstSource["url"] as? String,
              let url = URL(string: urlString) else {
            throw StreamingError.trackNotFound
        }
        return url
    }

    // MARK: - Parsers

    private func parseDeezerTrack(_ d: [String: Any]) -> StreamTrack? {
        guard let id = d["id"].map({ "\($0)" }),
              let title = d["title"] as? String else { return nil }

        let artist = (d["artist"] as? [String: Any])?["name"] as? String ?? ""
        let albumDict = d["album"] as? [String: Any]
        let album = albumDict?["title"] as? String ?? ""
        let albumID = albumDict?["id"].map { "\($0)" } ?? ""
        let duration = d["duration"] as? TimeInterval ?? 0
        let coverXL = (albumDict?["cover_xl"] as? String).flatMap { URL(string: $0) }
        let isrc = d["isrc"] as? String

        return StreamTrack(
            id: id, title: title, artist: artist,
            album: album, albumID: albumID, duration: duration,
            artworkURL: coverXL, source: .deezer, isrc: isrc,
            composer: nil, work: nil, conductor: nil
        )
    }

    private func parseDeezerAlbum(_ d: [String: Any]) -> StreamAlbum? {
        guard let id = d["id"].map({ "\($0)" }),
              let title = d["title"] as? String else { return nil }

        let artist = (d["artist"] as? [String: Any])?["name"] as? String ?? ""
        let coverXL = (d["cover_xl"] as? String).flatMap { URL(string: $0) }
        let year = (d["release_date"] as? String).flatMap { Int($0.prefix(4)) }
        let trackCount = d["nb_tracks"] as? Int

        return StreamAlbum(
            id: id, title: title, artist: artist,
            artworkURL: coverXL, year: year,
            source: .deezer, trackCount: trackCount
        )
    }
}
