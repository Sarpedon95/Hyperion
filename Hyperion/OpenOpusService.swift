import Foundation

// MARK: - Core Models

struct OOComposer: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let complete_name: String
    let epoch: String?
    let portrait: String?
    let birth: String?
    let death: String?

    static func == (lhs: OOComposer, rhs: OOComposer) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct OOWork: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let searchterms: String?
    let popular: String?
    let recommended: String?
    let genre: String?

    var isPopular: Bool { popular == "1" }
    var isRecommended: Bool { recommended == "1" }

    static func == (lhs: OOWork, rhs: OOWork) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct OOPerformer: Codable, Identifiable, Hashable {
    let name: String
    let role: String?
    let portrait: String?

    var id: String { name }

    static func == (lhs: OOPerformer, rhs: OOPerformer) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

struct OOGenreInfo: Codable, Identifiable {
    let name: String
    let count: String?
    var id: String { name }
}

struct OORandomWork: Codable, Identifiable {
    let work: OOWork
    let composer: OOComposer
    var id: String { work.id }
}

struct OOGuessRequest {
    let title: String
    let composer: String
}

struct OOGuessResult: Codable {
    let work: OOWork?
    let composer: OOComposer?
}

struct OOOmnisearchResult: Codable, Identifiable {
    let id: String
    let name: String
    let type: String      // "composer" | "work"
    let portrait: String?
    let epoch: String?
    let composer: OOComposer?
}

// MARK: - Response Wrappers

struct OOComposerListResponse: Codable {
    let composers: [OOComposer]?
    let status: OOStatus?
}

struct OOWorkListResponse: Codable {
    let works: [OOWork]?
    let status: OOStatus?
}

struct OOWorkDetailResponse: Codable {
    let work: OOWork?
    let composer: OOComposer?
    let performers: [OOPerformer]?
    let status: OOStatus?
}

struct OOGenreListResponse: Codable {
    let genres: [OOGenreInfo]?
    let status: OOStatus?
}

struct OORandomWorksResponse: Codable {
    let works: [OORandomWork]?
    let status: OOStatus?
}

struct OOPerformerListResponse: Codable {
    let performers: [OOPerformer]?
    let status: OOStatus?
}

struct OOGuessWorksResponse: Codable {
    let results: [OOGuessResult]?
    let status: OOStatus?
}

struct OOOmnisearchResponse: Codable {
    let results: [OOOmnisearchResult]?
    let status: OOStatus?
}

struct OOStatus: Codable {
    let success: String?
    let error: String?
    let version: String?
    let processingtime: Double?
}

// MARK: - Epoch + Genre

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
    var apiValue: String? { self == .all ? nil : rawValue }
}

enum OOGenre: String, CaseIterable, Identifiable {
    case orchestral = "Orchestral"
    case chamber    = "Chamber"
    case keyboard   = "Keyboard"
    case vocal      = "Vocal"
    case stage      = "Stage"

    var id: String { rawValue }
}

// MARK: - Service

@MainActor
final class OpenOpusService {

    static let shared = OpenOpusService()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy         = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                diskCapacity:  64 * 1024 * 1024,
                                diskPath: "openopus-cache")
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: Composers

    func popularComposers() async throws -> [OOComposer] {
        let r: OOComposerListResponse = try await get("/composer/list/popular.json")
        return r.composers ?? []
    }

    func essentialComposers() async throws -> [OOComposer] {
        let r: OOComposerListResponse = try await get("/composer/list/essential.json")
        return r.composers ?? []
    }

    func recommendedComposers() async throws -> [OOComposer] {
        let r: OOComposerListResponse = try await get("/composer/list/rec.json")
        return r.composers ?? []
    }

    func composersByLetter(_ letter: Character) async throws -> [OOComposer] {
        let l = String(letter).uppercased()
        let r: OOComposerListResponse = try await get("/composer/list/letter/\(l).json")
        return r.composers ?? []
    }

    func composersByEpoch(_ epoch: OOEpoch) async throws -> [OOComposer] {
        guard let ev = epoch.apiValue else { return try await recommendedComposers() }
        let enc = ev.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ev
        let r: OOComposerListResponse = try await get("/composer/list/epoch/\(enc).json")
        return r.composers ?? []
    }

    func searchComposers(name: String) async throws -> [OOComposer] {
        guard !name.isEmpty else { return try await recommendedComposers() }
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let r: OOComposerListResponse = try await get("/composer/list/search/\(enc).json")
        return r.composers ?? []
    }

    func composersByIDs(_ ids: [String]) async throws -> [OOComposer] {
        guard !ids.isEmpty else { return [] }
        let joined = ids.joined(separator: ",")
        let r: OOComposerListResponse = try await get("/composer/list/ids/\(joined).json")
        return r.composers ?? []
    }

    // MARK: Genres

    func genresForComposer(_ composerID: String) async throws -> [OOGenreInfo] {
        let r: OOGenreListResponse = try await get("/genre/list/composer/\(composerID).json")
        return r.genres ?? []
    }

    // MARK: Works

    func worksForComposer(_ composerID: String, genre: String = "all") async throws -> [OOWork] {
        let enc = genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre
        let r: OOWorkListResponse = try await get("/work/list/composer/\(composerID)/genre/\(enc).json")
        return r.works ?? []
    }

    func works(composerID: String, genre: String = "all") async throws -> [OOWork] {
        try await worksForComposer(composerID, genre: genre)
    }

    func workDetail(_ workID: String) async throws -> OOWorkDetailResponse {
        try await get("/work/detail/\(workID).json")
    }

    func worksByIDs(_ ids: [String]) async throws -> [OOWork] {
        guard !ids.isEmpty else { return [] }
        let joined = ids.joined(separator: ",")
        let r: OOWorkListResponse = try await get("/work/list/ids/\(joined).json")
        return r.works ?? []
    }

    // MARK: Dynamic / POST

    func randomWorks(
        genre: String? = nil,
        epoch: String? = nil,
        composer: String? = nil,
        popularWork: Bool = false
    ) async throws -> [OORandomWork] {
        var params: [String: String] = [:]
        if let g = genre,    !g.isEmpty { params["genre"]      = g }
        if let e = epoch,    !e.isEmpty { params["epoch"]      = e }
        if let c = composer, !c.isEmpty { params["composer"]   = c }
        if popularWork { params["popularwork"] = "1" }
        let r: OORandomWorksResponse = try await post("/dyn/work/random", formParams: params)
        return r.works ?? []
    }

    func performerRoles(names: [String]) async throws -> [OOPerformer] {
        guard !names.isEmpty else { return [] }
        let encoded = (try? String(data: JSONEncoder().encode(names), encoding: .utf8)) ?? "[]"
        let r: OOPerformerListResponse = try await post("/dyn/performer/role",
                                                        formParams: ["names": encoded])
        return r.performers ?? []
    }

    func guessWorks(_ requests: [OOGuessRequest]) async throws -> [OOGuessResult] {
        guard !requests.isEmpty else { return [] }
        let queries = requests.map { ["title": $0.title, "composer": $0.composer] }
        let encoded = (try? String(data: JSONEncoder().encode(queries), encoding: .utf8)) ?? "[]"
        let r: OOGuessWorksResponse = try await post("/dyn/work/guess",
                                                     formParams: ["queries": encoded])
        return r.results ?? []
    }

    // MARK: Omnisearch

    func omnisearch(_ query: String, offset: Int = 0) async throws -> [OOOmnisearchResult] {
        guard !query.isEmpty else { return [] }
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        let r: OOOmnisearchResponse = try await get("/dyn/omnisearch/\(enc)/\(offset).json")
        return r.results ?? []
    }

    // MARK: Full dump

    func downloadFullDump() async throws -> Data {
        guard let url = URL(string: "https://openopus.org/dump/works.json") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await session.data(from: url)
        return data
    }

    // MARK: - Networking primitives

    nonisolated private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "https://api.openopus.org" + path) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private func post<T: Decodable>(_ path: String, formParams: [String: String]) async throws -> T {
        guard let url = URL(string: "https://api.openopus.org" + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formParams
            .map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Levenshtein fuzzy match

extension String {
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
                    curr = 1 + Swift.min(dp[j-1], dp[j], prev)
                }
                dp[j-1] = prev
                prev = curr
            }
            dp[b.count] = prev
        }
        return dp[b.count]
    }

    func similarity(_ other: String) -> Double {
        let maxLen = Swift.max(self.count, other.count)
        guard maxLen > 0 else { return 1 }
        return 1.0 - Double(levenshtein(other)) / Double(maxLen)
    }
}
