import Foundation

// MARK: - Recording Group
// One performance in the LMS library: a contiguous set of tracks on one album
// belonging to the same work. tracks[] is populated after a track-fetch pass;
// until then lmsTrackIDs is the authoritative list.

struct RecordingGroup: Identifiable {
    let id: String              // "\(albumID):\(workTitle)"
    let workTitle: String
    let composer: String?
    let tracks: [Track]
    let albumID: Int
    let albumName: String
    let artworkTrackID: String?
    let conductor: String?
    let orchestra: String?
    let performer: String?      // soloists / primary artist

    var trackCount: Int { tracks.count }

    var performerSummary: String {
        var parts: [String] = []
        if let c = conductor, !c.isEmpty { parts.append(c) }
        if let o = orchestra, !o.isEmpty { parts.append(o) }
        if let p = performer, !p.isEmpty, p != conductor, p != orchestra { parts.append(p) }
        return parts.joined(separator: " / ")
    }
}

// MARK: - Work Recording Candidate
// A proposed link between one OpenOpus work and one LMS album/recording group.
// lmsTrackIDs is empty for album-level candidates (tracks fetched at play time).

struct WorkRecordingCandidate: Identifiable {

    enum MatchSource: String, Codable {
        case indexed   // scored by background LMSLibraryLinker
        case fallback  // live fuzzy search, not yet indexed
    }

    let id: String              // UUID string
    let openOpusWorkID: String
    let composerName: String
    let workTitle: String       // OO canonical title
    let lmsAlbumID: Int
    let lmsAlbumName: String
    let lmsTrackIDs: [Int]      // empty = play whole album
    let artworkTrackID: String?
    let confidence: Double      // 0.0–1.0
    let matchReason: String
    let source: MatchSource
    var userOverride: Bool = false
    var performerSummary: String?

    // Computed — not a memberwise init parameter
    var trackCount: Int { lmsTrackIDs.count }
}

// MARK: - Catalogue Number

enum CatalogueNumber {

    enum Signal {
        case match(reason: String)
        case conflict(reason: String)
        case absent
    }

    static let patterns: [(label: String, regex: NSRegularExpression)] = {
        let defs: [(String, String)] = [
            ("BWV",  #"BWV\.?\s*(\d+[a-z]?)"#),
            ("K",    #"\bKV?\.?\s*(\d+[a-z]?)"#),   // K and KV together
            ("Op",   #"\bOp(?:us)?\.?\s*(\d+(?:[,\.]\s*\d+)?)"#),
            ("D",    #"\bD\.?\s*(\d+[a-z]?)"#),
            ("Hob",  #"\bHob\.?\s*([IVX]+:\d+)"#),
            ("RV",   #"\bRV\.?\s*(\d+)"#),
            ("WAB",  #"\bWAB\.?\s*(\d+)"#),
            ("HWV",  #"\bHWV\.?\s*(\d+)"#),
        ]
        return defs.compactMap { label, pattern in
            guard let re = try? NSRegularExpression(pattern: pattern,
                                                    options: .caseInsensitive) else { return nil }
            return (label, re)
        }
    }()

    static func extract(from string: String) -> [String: String] {
        var results: [String: String] = [:]
        let ns = string as NSString
        let range = NSRange(location: 0, length: ns.length)
        for (label, re) in patterns {
            if let m = re.firstMatch(in: string, range: range) {
                let captured = ns.substring(with: m.range(at: 1))
                results[label] = captured.lowercased()
            }
        }
        return results
    }

    static func signal(albumTitle: String, ooTitle: String) -> Signal {
        let catAlbum = extract(from: albumTitle)
        let catOO    = extract(from: ooTitle)
        let shared   = Set(catAlbum.keys).intersection(Set(catOO.keys))
        guard !shared.isEmpty else { return .absent }
        for label in shared {
            let a = catAlbum[label]!
            let b = catOO[label]!
            if a == b {
                return .match(reason: "\(label)\(a)")
            } else {
                return .conflict(reason: "\(label)\(a) vs \(label)\(b)")
            }
        }
        return .absent
    }
}

// MARK: - Title Normalizer

enum TitleNormalizer {
    private static let stopWords: Set<String> = [
        "in", "for", "the", "a", "an", "and", "or", "no", "de",
        "major", "minor", "flat", "sharp", "number", "no"
    ]

    static func normalize(_ title: String) -> String {
        var s = title.lowercased()
        s = s.replacingOccurrences(of: #"\bin\s+[a-g][#b♭♯]?\s*(?:major|minor|flat|sharp)?\b"#,
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b[a-g][#b♭♯]?\b"#, with: "", options: .regularExpression)
        for (_, re) in CatalogueNumber.patterns {
            s = re.stringByReplacingMatches(in: s,
                                            range: NSRange(s.startIndex..., in: s),
                                            withTemplate: "")
        }
        s = s.components(separatedBy: .punctuationCharacters).joined(separator: " ")
        s = s.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty && !stopWords.contains($0) }
                .joined(separator: " ")
        return s
    }

    static func wordOverlapScore(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.split(whereSeparator: \.isWhitespace).map(String.init))
        let wordsB = Set(b.split(whereSeparator: \.isWhitespace).map(String.init))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        let common = Double(wordsA.intersection(wordsB).count)
        let denom  = Double(max(wordsA.count, wordsB.count))
        return common / denom
    }
}

// MARK: - Penalty detection

enum RecordingPenalty {
    // Terms that indicate a partial/transcribed/arranged recording
    private static let penaltyTerms = [
        "excerpt", "highlights", "highlight", "selections", "selected",
        "arr.", "arr ", "arrangement", "arranged by", "transcription", "transcribed",
        "single movement", "abridged", "suite",
    ]

    static func penalty(for title: String) -> Double {
        let lower = title.lowercased()
        return penaltyTerms.contains(where: { lower.contains($0) }) ? -0.20 : 0
    }
}

// MARK: - Candidate Scorer

enum CandidateScorer {

    struct Result {
        let confidence: Double
        let matchReason: String
    }

    /// Score a proposed link between an LMS album and an OO work.
    ///
    /// Scoring rules:
    /// - Base = 40% composer + 60% title.
    /// - A composer similarity below 0.30 (different composer) caps confidence at 0.40.
    /// - Catalogue number match adds +0.20; conflict adds -0.25.
    /// - Excerpt/arrangement penalty adds -0.20.
    /// - Title-only (no composer) can never exceed 0.50 without a catalogue match.
    static func score(
        albumTitle: String,
        albumComposer: String,
        albumArtist: String,
        ooTitle: String,
        ooComposerName: String,
        lmsWorkTag: String?
    ) -> Result {
        // Composer similarity — try both composer field and artist field
        let composerSim = max(
            albumComposer.isEmpty ? 0.0 : albumComposer.similarity(ooComposerName),
            albumArtist.isEmpty   ? 0.0 : albumArtist.similarity(ooComposerName)
        )

        // Title similarity
        let rawSim  = albumTitle.similarity(ooTitle)
        let normAlbum = TitleNormalizer.normalize(albumTitle)
        let normOO    = TitleNormalizer.normalize(ooTitle)
        let normSim  = normAlbum.similarity(normOO)
        let wordOver = TitleNormalizer.wordOverlapScore(normAlbum, normOO)

        // LMS work tag is the strongest title signal
        var lmsTagBoost: Double = 0
        if let tag = lmsWorkTag, !tag.isEmpty {
            let tagSim = tag.similarity(ooTitle)
            lmsTagBoost = tagSim > 0.8 ? 0.15 : 0
        }

        let titleSim = max(rawSim, normSim, wordOver * 0.9) + lmsTagBoost

        // Base confidence (weights sum to 1.0)
        var confidence = composerSim * 0.40 + min(titleSim, 1.0) * 0.60

        // Catalogue signal
        let catSignal = CatalogueNumber.signal(albumTitle: albumTitle, ooTitle: ooTitle)
        var catReason: String? = nil
        switch catSignal {
        case .match(let r):
            confidence += 0.20
            catReason = "cat:\(r)"
        case .conflict(let r):
            confidence -= 0.25
            catReason = "cat conflict:\(r)"
        case .absent:
            break
        }

        // Excerpt/arrangement penalty
        let excerptPenalty = RecordingPenalty.penalty(for: albumTitle)
        confidence += excerptPenalty

        // Composer-mismatch hard cap: if neither composer nor artist looks like the OO composer,
        // cap at 0.40 so a title-only match cannot appear high-confidence.
        if composerSim < 0.30 {
            confidence = min(confidence, 0.40)
        }

        confidence = confidence.clamped(to: 0...1)

        // Build reason string
        var reasons: [String] = []
        if composerSim > 0.75  { reasons.append("composer") }
        else if composerSim < 0.30 { reasons.append("composer mismatch") }
        if normSim > 0.70      { reasons.append("title") }
        else if rawSim > 0.60  { reasons.append("title (approx)") }
        if lmsTagBoost > 0     { reasons.append("work tag") }
        if let cr = catReason  { reasons.append(cr) }
        if excerptPenalty < 0  { reasons.append("excerpt/arr penalty") }
        let reason = reasons.isEmpty ? "weak fuzzy match" : reasons.joined(separator: ", ")

        return Result(confidence: confidence, matchReason: reason)
    }
}
