// SquidClient.swift
// Hyperion — SquidWTF (Subsonic) Streaming Integration
// Personal use only — talks to any Subsonic-compatible server

import Foundation
import CryptoKit

final class SquidClient: StreamingSource {

    static let shared = SquidClient()
    private init() {}

    let name = "Squid"
    let sourceType: StreamSourceType = .squid

    private func log(_ s: String) {
        Task { @MainActor in ServerLogStore.shared.debug("[Squid] \(s)") }
    }

    // MARK: - Credentials (from Keychain)

    private var serverURL: String? {
        KeychainManager.shared.load(key: "squid.serverURL")
    }
    private var username: String? {
        KeychainManager.shared.load(key: "squid.username")
    }
    private var password: String? {
        KeychainManager.shared.load(key: "squid.password")
    }

    var isAvailable: Bool {
        get async {
            guard let url = serverURL, !url.isEmpty,
                  let user = username, !user.isEmpty,
                  let pw = password, !pw.isEmpty else { return false }
            return true
        }
    }

    // MARK: - Subsonic auth params
    //
    // Subsonic salted-token auth: t = md5(password + salt), s = random salt.
    // Salt regenerated per request so a captured (t, s) pair cannot be replayed.

    private static let apiVersion = "1.16.1"
    private static let clientName = "Hyperion"

    private func authParams() -> [URLQueryItem]? {
        guard let user = username, let pw = password else { return nil }
        let salt = Self.randomSalt(length: 8)
        let token = md5Hex(pw + salt)
        return [
            URLQueryItem(name: "u", value: user),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    private func endpoint(_ path: String, params: [String: String] = [:]) -> URL? {
        guard let base = serverURL, !base.isEmpty,
              let auth = authParams() else { return nil }
        // Allow the user to enter the server URL with or without a trailing slash.
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard var comps = URLComponents(string: trimmed + path) else { return nil }
        var items = auth
        for (k, v) in params { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        return comps.url
    }

    // MARK: - Request helper

    private func getJSON(_ path: String, params: [String: String] = [:]) async -> [String: Any]? {
        guard let url = endpoint(path, params: params) else {
            log("request \(path) skipped — missing server URL / credentials")
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["subsonic-response"] as? [String: Any] else {
                log("request \(path): HTTP \(code), unparseable response")
                return nil
            }
            if let status = body["status"] as? String, status != "ok" {
                let err = (body["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                log("request \(path): status=\(status) error=\(err)")
                return nil
            }
            return body
        } catch {
            log("request \(path): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Search

    func search(query: String) async -> [StreamTrack] {
        guard !query.isEmpty else { return [] }
        guard let body = await getJSON("/rest/search3.json",
                                       params: ["query": query,
                                                "songCount": "30",
                                                "albumCount": "20",
                                                "artistCount": "0"]),
              let result = body["searchResult3"] as? [String: Any] else { return [] }
        let songs = result["song"] as? [[String: Any]] ?? []
        let parsed = songs.compactMap { parseSubsonicSong($0) }
        log("search '\(query)': \(songs.count) raw → \(parsed.count) tracks")
        return parsed
    }

    func searchAlbums(query: String) async -> [StreamAlbum] {
        guard !query.isEmpty else { return [] }
        guard let body = await getJSON("/rest/search3.json",
                                       params: ["query": query,
                                                "songCount": "0",
                                                "albumCount": "20",
                                                "artistCount": "0"]),
              let result = body["searchResult3"] as? [String: Any] else { return [] }
        let albums = result["album"] as? [[String: Any]] ?? []
        return albums.compactMap { parseSubsonicAlbum($0) }
    }

    // MARK: - Album

    func getAlbum(id: String) async throws -> StreamAlbum {
        guard let body = await getJSON("/rest/getAlbum.json", params: ["id": id]),
              let album = body["album"] as? [String: Any],
              let parsed = parseSubsonicAlbum(album) else {
            throw StreamingError.trackNotFound
        }
        return parsed
    }

    func getAlbumTracks(albumID: String) async -> [StreamTrack] {
        guard let body = await getJSON("/rest/getAlbum.json", params: ["id": albumID]),
              let album = body["album"] as? [String: Any] else { return [] }
        let songs = album["song"] as? [[String: Any]] ?? []
        let albumTitle = album["name"] as? String
        let albumArtist = album["artist"] as? String
        return songs.compactMap { parseSubsonicSong($0,
                                                    fallbackAlbumTitle: albumTitle,
                                                    fallbackAlbumArtist: albumArtist) }
    }

    // MARK: - Favorites (Subsonic "starred")

    func getUserFavorites() async -> [StreamTrack] {
        guard let body = await getJSON("/rest/getStarred2.json"),
              let starred = body["starred2"] as? [String: Any] else { return [] }
        let songs = starred["song"] as? [[String: Any]] ?? []
        return songs.compactMap { parseSubsonicSong($0) }
    }

    func getUserFavoriteAlbums() async -> [StreamAlbum] {
        guard let body = await getJSON("/rest/getStarred2.json"),
              let starred = body["starred2"] as? [String: Any] else { return [] }
        let albums = starred["album"] as? [[String: Any]] ?? []
        return albums.compactMap { parseSubsonicAlbum($0) }
    }

    // MARK: - Stream URL
    //
    // Subsonic streams are not encrypted — /rest/stream returns the audio
    // directly, so we can hand the signed URL straight to AVPlayer.

    func getStreamURL(for track: StreamTrack) async throws -> URL {
        guard await isAvailable else {
            log("getStreamURL: missing credentials")
            throw StreamingError.authenticationFailed
        }
        guard let url = endpoint("/rest/stream.json", params: ["id": track.id]) else {
            throw StreamingError.trackNotFound
        }
        return url
    }

    // MARK: - Parsers

    private func parseSubsonicSong(
        _ d: [String: Any],
        fallbackAlbumTitle: String? = nil,
        fallbackAlbumArtist: String? = nil
    ) -> StreamTrack? {
        guard let id = d["id"] as? String,
              let title = d["title"] as? String else { return nil }

        let artist = d["artist"] as? String ?? fallbackAlbumArtist ?? ""
        let album = d["album"] as? String ?? fallbackAlbumTitle ?? ""
        let albumID = d["albumId"] as? String ?? ""
        let duration = (d["duration"] as? TimeInterval)
            ?? (d["duration"] as? Int).map { TimeInterval($0) }
            ?? 0
        let artworkURL = coverArtURL(coverArtID: d["coverArt"] as? String)

        return StreamTrack(
            id: id, title: title, artist: artist,
            album: album, albumID: albumID, duration: duration,
            artworkURL: artworkURL, source: .squid, isrc: nil,
            composer: nil, work: nil, conductor: nil
        )
    }

    private func parseSubsonicAlbum(_ d: [String: Any]) -> StreamAlbum? {
        guard let id = d["id"] as? String,
              let title = d["name"] as? String else { return nil }

        let artist = d["artist"] as? String ?? ""
        let year = d["year"] as? Int
        let trackCount = d["songCount"] as? Int
        let artworkURL = coverArtURL(coverArtID: d["coverArt"] as? String)

        return StreamAlbum(
            id: id, title: title, artist: artist,
            artworkURL: artworkURL, year: year,
            source: .squid, trackCount: trackCount
        )
    }

    private func coverArtURL(coverArtID: String?) -> URL? {
        guard let coverArtID, !coverArtID.isEmpty else { return nil }
        return endpoint("/rest/getCoverArt.json", params: ["id": coverArtID])
    }

    // MARK: - Helpers

    private func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSalt(length: Int) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }
}
