import Foundation

// MARK: - OpenOpus Codable models

struct OOComposer: Codable, Identifiable, Hashable {
    let id: String          // OpenOpus uses string IDs
    let name: String
    let complete_name: String
    let epoch: String?      // "Baroque", "Romantic", etc.
    let portrait: String?   // URL string for portrait image

    static func == (lhs: OOComposer, rhs: OOComposer) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct OOWork: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let searchterms: String?
    let popular: String?    // "1" if popular
    let recommended: String?
    let genre: String?

    var isPopular: Bool { popular == "1" }

    static func == (lhs: OOWork, rhs: OOWork) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct OOComposerListResponse: Codable {
    let composers: [OOComposer]?
    let status: OOStatus?
}

struct OOWorkListResponse: Codable {
    let works: [OOWork]?
    let status: OOStatus?
}

struct OOStatus: Codable {
    let success: String?
    let error: String?
    let version: String?
    let processingtime: Double?
}

// MARK: - Epoch

enum OOEpoch: String, CaseIterable, Identifiable {
    case all          = "All"
    case medieval     = "Medieval"
    case renaissance  = "Renaissance"
    case baroque      = "Baroque"
    case classical    = "Classical"
    case romantic     = "Romantic"
    case modern       = "Modern"
    case contemporary = "Contemporary"

    var id: String { rawValue }

    var apiValue: String? {
        self == .all ? nil : rawValue
    }
}

// MARK: - Genre groups

enum OOGenre: String, CaseIterable, Identifiable {
    case orchestral = "Orchestral"
    case chamber    = "Chamber"
    case keyboard   = "Keyboard"
    case vocal      = "Vocal"
    case stage      = "Stage"

    var id: String { rawValue }
}

// MARK: - OpenOpus API service

@MainActor
final class OpenOpusService {

    static let shared = OpenOpusService()

    private let baseURL = "https://api.openopus.org"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy         = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 8*1024*1024,
                                diskCapacity:  32*1024*1024,
                                diskPath: "openopus-cache")
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Public API

    func recommendedComposers() async throws -> [OOComposer] {
        let resp: OOComposerListResponse = try await get(path: "/composer/list/rec.json")
        return resp.composers ?? []
    }

    func searchComposers(name: String) async throws -> [OOComposer] {
        guard !name.isEmpty else { return try await recommendedComposers() }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let resp: OOComposerListResponse = try await get(path: "/composer/list/search/\(encoded).json")
        return resp.composers ?? []
    }

    func composersByEpoch(_ epoch: OOEpoch) async throws -> [OOComposer] {
        guard let epochValue = epoch.apiValue else { return try await recommendedComposers() }
        let encoded = epochValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? epochValue
        let resp: OOComposerListResponse = try await get(path: "/composer/list/epoch/\(encoded).json")
        return resp.composers ?? []
    }

    func works(composerID: String, genre: String = "all") async throws -> [OOWork] {
        let resp: OOWorkListResponse = try await get(path: "/work/list/composer/\(composerID)/genre/\(genre).json")
        return resp.works ?? []
    }

    // MARK: - Private

    nonisolated private func get<T: Codable>(path: String) async throws -> T {
        guard let url = URL(string: "https://api.openopus.org" + path) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Levenshtein distance for fuzzy matching

extension String {
    /// Returns the Levenshtein edit distance between self and other.
    func levenshtein(_ other: String) -> Int {
        let a = Array(self.lowercased())
        let b = Array(other.lowercased())
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = i
            for j in 1...b.count {
                let curr: Int
                if a[i-1] == b[j-1] {
                    curr = dp[j-1]
                } else {
                    curr = 1 + min(dp[j-1], dp[j], prev)
                }
                dp[j-1] = prev
                prev = curr
            }
            dp[b.count] = prev
        }
        return dp[b.count]
    }

    /// Normalised similarity 0…1 (1 = identical).
    func similarity(_ other: String) -> Double {
        let maxLen = max(self.count, other.count)
        guard maxLen > 0 else { return 1 }
        return 1.0 - Double(levenshtein(other)) / Double(maxLen)
    }
}
