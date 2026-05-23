import Foundation

// MARK: - RadioBrowser API client
//
// Thin client for https://api.radio-browser.info — free, no API key.
// Every method returns an empty array on any failure (never throws to the UI).
// RadioBrowser asks clients to send a descriptive User-Agent and to call the
// click endpoint when a station starts playing.

final class RadioBrowserAPI {

    static let shared = RadioBrowserAPI()

    private let base = "https://api.radio-browser.info/json"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadRevalidatingCacheData
        return URLSession(configuration: config)
    }()

    private let userAgent = "Hyperion/1.0 (+https://hyperion.app)"

    private init() {}

    // MARK: - Public queries

    func searchStations(query: String) async -> [RadioStation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let path = "/stations/search"
        let items = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        return await fetch(path: path, queryItems: items)
    }

    func browseByGenre(tag: String) async -> [RadioStation] {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // bytag takes the tag in the path; encode it as a single path component.
        let path = "/stations/bytag/" + pathEncoded(trimmed)
        let items = [
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        return await fetch(path: path, queryItems: items)
    }

    func browseByLanguage(language: String) async -> [RadioStation] {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let path = "/stations/bylanguage/" + pathEncoded(trimmed)
        let items = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        return await fetch(path: path, queryItems: items)
    }

    func fetchTopStations(limit: Int = 20) async -> [RadioStation] {
        let path = "/stations"
        let items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        return await fetch(path: path, queryItems: items)
    }

    /// Resolve a single station by name and return the highest-vote match. Used
    /// to refresh featured stations' stream URLs at runtime.
    func bestMatch(name: String) async -> RadioStation? {
        let results = await searchStations(query: name)
        // Prefer an exact (case-insensitive) name match, else the top-voted result.
        if let exact = results.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            return exact
        }
        return results.first
    }

    /// RadioBrowser click counter — call when a station begins playing.
    /// Fire-and-forget; the documented endpoint is GET /json/url/{uuid}.
    func recordClick(stationUUID: String) async {
        let trimmed = stationUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(base)/url/\(pathEncoded(trimmed))") else { return }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try? await session.data(for: req)
    }

    // MARK: - Internal

    private func fetch(path: String, queryItems: [URLQueryItem]) async -> [RadioStation] {
        guard var components = URLComponents(string: base + path) else { return [] }
        // bytag/bylanguage already encode the value in the path; only append a
        // query string when there are query items beyond the path component.
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { return [] }

        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return arr.compactMap { Self.station(from: $0, isFeatured: false) }
        } catch {
            return []
        }
    }

    /// Maps a RadioBrowser station dict to a RadioStation. Uses url_resolved
    /// (the verified playable URL) and keeps only http(s) streams.
    static func station(from dict: [String: Any], isFeatured: Bool) -> RadioStation? {
        let uuid = (dict["stationuuid"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawURL = (dict["url_resolved"] as? String)
            ?? (dict["url"] as? String)
            ?? ""
        guard !uuid.isEmpty || isFeatured,
              !name.isEmpty,
              rawURL.lowercased().hasPrefix("http"),
              let streamURL = URL(string: rawURL) else { return nil }

        let tags = (dict["tags"] as? String) ?? ""
        let firstTag = tags.split(separator: ",").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let faviconStr = (dict["favicon"] as? String) ?? ""
        let logoURL = faviconStr.lowercased().hasPrefix("http") ? URL(string: faviconStr) : nil

        return RadioStation(
            id:        uuid.isEmpty ? "seed:\(name)" : uuid,
            name:      name,
            streamURL: streamURL,
            genre:     (firstTag?.isEmpty == false) ? firstTag : nil,
            country:   nonEmpty(dict["country"] as? String),
            language:  nonEmpty((dict["language"] as? String)?.split(separator: ",").first.map(String.init)),
            logoURL:   logoURL,
            bitrate:   intValue(dict["bitrate"]),
            codec:     nonEmpty(dict["codec"] as? String),
            votes:     intValue(dict["votes"]),
            isFeatured: isFeatured
        )
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    private func pathEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
