import Foundation

// Persistent disk cache for the full OpenOpus composer catalogue.
//
// On first access (cold start, no cache file) fetches all 26 letter endpoints
// in parallel and writes `Caches/oo_composer_cache.json`.
// On subsequent accesses within 7 days the cache file is returned instantly.
// When the cache is stale (age > 7 days) the stored list is returned immediately
// while a background task silently refreshes it.

actor OOComposerCache {

    static let shared = OOComposerCache()

    private let cacheURL: URL
    private let ttl: TimeInterval = 7 * 24 * 3600   // 7 days

    private var inMemory: [OOComposer]?
    private var refreshTask: Task<Void, Never>?

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = caches.appendingPathComponent("oo_composer_cache.json")
    }

    // MARK: - Public API

    /// Returns the cached composer list, fetching from disk or network as needed.
    /// Always returns promptly — stale caches trigger a silent background refresh.
    func composers() async -> [OOComposer] {
        if let mem = inMemory { return mem }

        if let (list, age) = loadFromDisk() {
            inMemory = list
            if age > ttl {
                scheduleBackgroundRefresh()
            }
            return list
        }

        // Nothing on disk — block until we have a fresh list.
        let fresh = await fetchAll()
        inMemory = fresh
        if !fresh.isEmpty { saveToDisk(fresh) }
        return fresh
    }

    /// Returns a folded-name → epoch dictionary for cross-referencing LMS composers.
    /// Keys are normalised with SearchTextNormalizer.folded so matching is
    /// case- and diacritic-insensitive.
    ///
    /// AUDIT-FIX: LMS and OpenOpus names diverge (romanisation, name order, suffixes).
    /// Two-pass population so exact matches always beat last-name collisions:
    ///   Pass 1 — full-name variants per composer:
    ///     • `c.name` and `c.complete_name` (folded)
    ///     • reversed-order ("Lastname, Firstname" ↔ "Firstname Lastname")
    ///     • suffix-stripped ("Jr.", "Sr.", "II", "III", "IV")
    ///   Pass 2 — last-name-only fallback so an LMS tag with just the surname
    ///   ("Mozart", "Bach") still resolves. First-composer-wins on collisions.
    func epochByName() async -> [String: OOEpoch] {
        let list = await composers()
        var dict: [String: OOEpoch] = [:]
        // Pass 1: exact / reversed / suffix-stripped full-name variants.
        for c in list {
            guard let epochStr = c.epoch,
                  let epoch = OOEpoch(rawValue: epochStr) else { continue }
            for variant in Self.nameVariants(name: c.name, completeName: c.complete_name) {
                if dict[variant] == nil { dict[variant] = epoch }
            }
        }
        // Pass 2: last-name-only fallback. Runs after Pass 1 so a composer whose
        // full name happens to be just a surname (e.g. "Mozart") still wins over
        // another composer's last-name extraction.
        for c in list {
            guard let epochStr = c.epoch,
                  let epoch = OOEpoch(rawValue: epochStr) else { continue }
            for variant in Self.lastNameOnlyVariants(name: c.name, completeName: c.complete_name) {
                if dict[variant] == nil { dict[variant] = epoch }
            }
        }
        return dict
    }

    /// Suffixes occasionally appended to performer/composer surnames that we must
    /// strip before comparing OO ↔ LMS names. Match is whole-token, case-insensitive.
    private static let strippableSuffixes: [String] = [
        "jr", "jr.", "sr", "sr.", "ii", "iii", "iv"
    ]

    /// Generates folded name variants for a single OO composer entry. Each variant
    /// is suitable as a lookup key in the epoch dictionary. Suffix stripping is
    /// applied BEFORE comma-reversal so "Strauss, Johann II" yields the variant
    /// "Johann Strauss" rather than the malformed "Johann II Strauss".
    static func nameVariants(name: String, completeName: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let folded = SearchTextNormalizer.folded(trimmed)
            guard !folded.isEmpty, seen.insert(folded).inserted else { return }
            out.append(folded)
        }

        // Collect raw source strings: original + suffix-stripped variants.
        var sources: [String] = []
        for raw in [name, completeName] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sources.append(trimmed)
            let stripped = stripSuffixes(trimmed)
            if stripped != trimmed, !stripped.isEmpty { sources.append(stripped) }
        }

        // For each raw source, emit the source plus its order-reversed twin
        // (comma-order ↔ space-order). The reversed form handles LMS tags that
        // store the name as "Firstname Lastname" instead of OO's "Lastname, Firstname".
        for src in sources {
            add(src)
            if let reversed = reverseCommaOrdered(src) {
                add(reversed)
            } else if let reversed = toCommaOrdered(src) {
                add(reversed)
            }
        }
        return out
    }

    /// "Lastname, Firstname Middlename" → "Firstname Middlename Lastname".
    /// Returns nil if the input has no comma.
    private static func reverseCommaOrdered(_ s: String) -> String? {
        let parts = s.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let last = parts[0].trimmingCharacters(in: .whitespaces)
        let first = parts[1].trimmingCharacters(in: .whitespaces)
        guard !last.isEmpty, !first.isEmpty else { return nil }
        return "\(first) \(last)"
    }

    /// "Firstname Middlename Lastname" → "Lastname, Firstname Middlename".
    /// Returns nil if the input has fewer than two whitespace-separated tokens
    /// or already contains a comma (assumed already in canonical form).
    private static func toCommaOrdered(_ s: String) -> String? {
        if s.contains(",") { return nil }
        let tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let last = tokens.last!
        let rest = tokens.dropLast().joined(separator: " ")
        return "\(last), \(rest)"
    }

    /// Folded last-name-only variants for a composer, used as the final-fallback
    /// matching pass in `epochByName`. Suffixes are stripped before extracting
    /// the surname so "Strauss, Johann II" yields "Strauss" rather than "II".
    static func lastNameOnlyVariants(name: String, completeName: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in [name, completeName] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cleaned = stripSuffixes(trimmed)
            guard let last = extractLastName(cleaned) else { continue }
            let folded = SearchTextNormalizer.folded(last)
            guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
            out.append(folded)
        }
        return out
    }

    /// "Lastname, Firstname …" → "Lastname".
    /// "Firstname … Lastname"  → "Lastname".
    /// Single-token names ("Madonna") return themselves.
    private static func extractLastName(_ s: String) -> String? {
        if let commaIdx = s.firstIndex(of: ",") {
            let last = s[..<commaIdx].trimmingCharacters(in: .whitespaces)
            return last.isEmpty ? nil : String(last)
        }
        let tokens = s.split(whereSeparator: { $0.isWhitespace })
        guard let last = tokens.last, !last.isEmpty else { return nil }
        return String(last)
    }

    /// Strips trailing suffix tokens (Jr., Sr., II, III, IV) from a name, also
    /// stripping any orphaned trailing comma left behind by the removal. Operates
    /// on the raw string so downstream variant generators can still see the
    /// original word order and casing.
    private static func stripSuffixes(_ s: String) -> String {
        var tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let last = tokens.last {
            let cleaned = last.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if strippableSuffixes.contains(cleaned) {
                tokens.removeLast()
            } else {
                break
            }
        }
        var result = tokens.joined(separator: " ")
        if result.hasSuffix(",") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Forces an immediate refresh (e.g. pull-to-refresh).
    func refresh() async {
        let fresh = await fetchAll()
        guard !fresh.isEmpty else { return }
        inMemory = fresh
        saveToDisk(fresh)
    }

    // MARK: - Internals

    private func scheduleBackgroundRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await self.refresh()
            self.refreshTask = nil
        }
    }

    // MARK: Network fetch

    private func fetchAll() async -> [OOComposer] {
        // AUDIT-FIX #11 — cap concurrency to 4 to avoid flooding OpenOpus on cold
        // start; 26 simultaneous requests caused frequent 429s and connection resets.
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var seen = Set<String>()
        var all: [OOComposer] = []
        all.reserveCapacity(2000)

        let chunkSize = 4
        for chunkStart in stride(from: 0, to: letters.count, by: chunkSize) {
            let chunk = letters[chunkStart..<min(chunkStart + chunkSize, letters.count)]
            let batch = await withTaskGroup(of: [OOComposer].self) { group in
                for letter in chunk {
                    group.addTask {
                        (try? await OpenOpusService.shared.composersByLetter(letter)) ?? []
                    }
                }
                var results: [OOComposer] = []
                for await composers in group { results.append(contentsOf: composers) }
                return results
            }
            for c in batch where seen.insert(c.id).inserted { all.append(c) }
        }
        return all.sorted { $0.name < $1.name }
    }

    // MARK: Disk I/O

    private struct Payload: Codable {
        let composers: [OOComposer]
        let fetchedAt: Date
    }

    private func loadFromDisk() -> ([OOComposer], TimeInterval)? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(payload.fetchedAt)
        return (payload.composers, age)
    }

    private func saveToDisk(_ composers: [OOComposer]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Payload(composers: composers, fetchedAt: Date())) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
