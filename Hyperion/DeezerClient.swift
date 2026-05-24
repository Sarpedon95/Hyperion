// DeezerClient.swift
// Hyperion — Deezer Streaming Integration
// Personal use only — uses ARL cookie authentication

import Foundation
import CryptoKit
import CommonCrypto

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

    /// Returns nil only if the api base + path fails to parse as a URL
    /// (which would indicate a programming error, not user input). All
    /// call sites guard the result so a malformed URL becomes a silent
    /// "no results" rather than a crash.
    private func apiURL(_ path: String, params: [String: String] = [:]) -> URL? {
        guard var comps = URLComponents(string: apiBase + path) else { return nil }
        if !params.isEmpty {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url
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
        guard let url = apiURL("/search", params: ["q": query, "limit": "30"]) else { return [] }
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
        guard let url = apiURL("/search/album", params: ["q": query, "limit": "20"]) else { return [] }
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerAlbum($0) }
    }

    // MARK: - Album

    func getAlbum(id: String) async throws -> StreamAlbum {
        guard let url = apiURL("/album/\(id)") else { throw StreamingError.trackNotFound }
        let data = try await session().data(from: url).0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let album = parseDeezerAlbum(json) else { throw StreamingError.trackNotFound }
        return album
    }

    func getAlbumTracks(albumID: String) async -> [StreamTrack] {
        guard let url = apiURL("/album/\(albumID)/tracks", params: ["limit": "100"]) else { return [] }
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerTrack($0) }
    }

    // MARK: - Favorites

    func getUserFavorites() async -> [StreamTrack] {
        guard let url = apiURL("/user/me/tracks", params: ["limit": "500"]) else { return [] }
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerTrack($0) }
    }

    func getUserFavoriteAlbums() async -> [StreamAlbum] {
        guard let url = apiURL("/user/me/albums", params: ["limit": "200"]) else { return [] }
        guard let data = try? await session().data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseDeezerAlbum($0) }
    }

    // MARK: - Stream URL
    //
    // Deezer full-quality streams are Blowfish-encrypted (BF_CBC_STRIPE), so the
    // CDN URL cannot be handed to AVPlayer directly. The flow (personal use):
    //   1. getUserData  → api_token (checkForm) + user license_token
    //   2. song.getListData → per-track TRACK_TOKEN
    //   3. media.deezer.com/v1/get_url → encrypted CDN URL (+ format)
    //   4. download, Blowfish-decrypt the striped chunks, cache a playable file
    // getStreamURL returns a local file:// URL the rest of the pipeline plays
    // like any other local track.

    func getStreamURL(for track: StreamTrack) async throws -> URL {
        guard let arl else {
            log("getStreamURL: no Deezer ARL in Keychain")
            throw StreamingError.authenticationFailed
        }

        // Reuse a previously decrypted file if we already fetched this track.
        for ext in ["flac", "mp3"] {
            let cached = decryptedFileURL(trackID: track.id, ext: ext)
            if FileManager.default.fileExists(atPath: cached.path) {
                log("getStreamURL: reusing cached \(cached.lastPathComponent)")
                return cached
            }
        }

        let (apiToken, licenseToken) = try await fetchUserData(arl: arl)
        let trackToken = try await fetchTrackToken(trackID: track.id, apiToken: apiToken)
        let (encURL, format) = try await fetchMediaURL(trackToken: trackToken, licenseToken: licenseToken)

        log("getStreamURL: downloading \(format) for track \(track.id)")
        let (encData, response) = try await URLSession.shared.data(from: encURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            log("getStreamURL: media download HTTP \(http.statusCode)")
            throw StreamingError.trackNotFound
        }

        let decrypted = Self.decryptDeezerStream(encData, trackID: track.id)
        let ext = format.uppercased().contains("FLAC") ? "flac" : "mp3"
        let outURL = decryptedFileURL(trackID: track.id, ext: ext)
        try decrypted.write(to: outURL, options: .atomic)
        log("getStreamURL: decrypted \(decrypted.count) bytes → \(outURL.lastPathComponent)")
        return outURL
    }

    private func decryptedFileURL(trackID: String, ext: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deezer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dz-\(trackID).\(ext)")
    }

    private func fetchUserData(arl: String) async throws -> (apiToken: String, licenseToken: String) {
        guard var comps = URLComponents(string: gwBase) else {
            throw StreamingError.authenticationFailed
        }
        comps.queryItems = [
            URLQueryItem(name: "method", value: "deezer.getUserData"),
            URLQueryItem(name: "api_version", value: "1.0"),
            URLQueryItem(name: "api_token", value: "null"),
            URLQueryItem(name: "input", value: "3"),
        ]
        guard let url = comps.url else { throw StreamingError.authenticationFailed }
        var req = URLRequest(url: url)
        req.setValue("arl=\(arl)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let apiToken = results["checkForm"] as? String else {
            log("fetchUserData: no checkForm — ARL likely invalid/expired")
            throw StreamingError.authenticationFailed
        }
        let licenseToken = ((results["USER"] as? [String: Any])?["OPTIONS"] as? [String: Any])?["license_token"] as? String ?? ""
        if licenseToken.isEmpty { log("fetchUserData: empty license_token (free account or expired ARL?)") }
        return (apiToken, licenseToken)
    }

    private func fetchTrackToken(trackID: String, apiToken: String) async throws -> String {
        guard var comps = URLComponents(string: gwBase) else {
            throw StreamingError.trackNotFound
        }
        comps.queryItems = [
            URLQueryItem(name: "method", value: "song.getListData"),
            URLQueryItem(name: "api_version", value: "1.0"),
            URLQueryItem(name: "api_token", value: apiToken),
        ]
        guard let url = comps.url else { throw StreamingError.trackNotFound }
        var req = URLRequest(url: url)
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

    /// Modern Deezer media endpoint. Returns the encrypted CDN URL + the format
    /// that was actually served (depends on the account's subscription tier).
    private func fetchMediaURL(trackToken: String, licenseToken: String) async throws -> (url: URL, format: String) {
        let body: [String: Any] = [
            "license_token": licenseToken,
            "media": [["type": "FULL", "formats": [
                ["cipher": "BF_CBC_STRIPE", "format": "FLAC"],
                ["cipher": "BF_CBC_STRIPE", "format": "MP3_320"],
                ["cipher": "BF_CBC_STRIPE", "format": "MP3_128"],
            ]]],
            "track_tokens": [trackToken],
        ]
        guard let mediaURL = URL(string: "https://media.deezer.com/v1/get_url") else {
            throw StreamingError.trackNotFound
        }
        var req = URLRequest(url: mediaURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]],
              let first = results.first else {
            throw StreamingError.trackNotFound
        }
        if let errors = first["errors"] as? [[String: Any]], !errors.isEmpty {
            log("fetchMediaURL: \(errors)")
            throw StreamingError.trackNotFound
        }
        guard let media = first["media"] as? [[String: Any]],
              let firstMedia = media.first,
              let sources = firstMedia["sources"] as? [[String: Any]],
              let urlString = sources.first?["url"] as? String,
              let url = URL(string: urlString) else {
            throw StreamingError.trackNotFound
        }
        let format = firstMedia["format"] as? String ?? "MP3_320"
        return (url, format)
    }

    // MARK: - Blowfish decryption (BF_CBC_STRIPE)
    //
    // Deezer encrypts every third 2048-byte chunk with Blowfish-CBC; the rest is
    // plaintext. The per-track key derives from md5(sng_id) XOR'd with a fixed
    // secret. Personal-use decryption only.

    private static let blowfishSecret = "g4el58wc0zvf9na1"

    private static func blowfishKey(trackID: String) -> [UInt8] {
        let md5 = Insecure.MD5.hash(data: Data(trackID.utf8)).map { String(format: "%02x", $0) }.joined()
        let m = Array(md5.utf8)            // 32 ASCII hex chars
        let s = Array(blowfishSecret.utf8) // 16 chars
        guard m.count >= 32 else { return Array(repeating: 0, count: 16) }
        var key = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { key[i] = m[i] ^ m[i + 16] ^ s[i] }
        return key
    }

    static func decryptDeezerStream(_ data: Data, trackID: String) -> Data {
        let key = blowfishKey(trackID: trackID)
        let iv: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let chunkSize = 2048
        let bytes = [UInt8](data)
        var output = Data(capacity: bytes.count)
        var offset = 0
        var index = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = Array(bytes[offset..<end])
            if index % 3 == 0 && chunk.count == chunkSize,
               let dec = blowfishDecryptCBC(chunk, key: key, iv: iv) {
                output.append(contentsOf: dec)
            } else {
                output.append(contentsOf: chunk)
            }
            offset = end
            index += 1
        }
        return output
    }

    private static func blowfishDecryptCBC(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeBlowfish)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmBlowfish),
            0,                       // BF_CBC_STRIPE chunks are exact blocks — no padding
            key, key.count,
            iv,
            data, data.count,
            &out, out.count,
            &moved
        )
        guard status == Int32(kCCSuccess) else { return nil }
        return Array(out.prefix(moved))
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
