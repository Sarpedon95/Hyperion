import Foundation

struct ClassicalMetadata: Equatable {
    // From SOURCE A (LMS JSON-RPC)
    let work: String?           // full canonical work title
    let workID: Int?            // works table FK
    let ensemble: String?       // band field from LMS
    let composer: String?       // already in Track but repeated here for clarity
    let conductor: String?      // already in Track but repeated here
    let recordingYear: Int?     // year field — recording year only

    // From SOURCE B (ClassicalTags plugin)
    let soloist: String?        // semicolon-separated, nil if none
    let section: String?        // opera/oratorio only, nil otherwise
    let workID_slug: String?    // disambiguation slug, nil if single performance

    // Derived
    var soloists: [String] {
        guard let s = soloist else { return [] }
        return s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var isPartOfWork: Bool { work != nil }
    var hasSection: Bool { section != nil }
    var hasDisambiguation: Bool { workID_slug != nil }

    static let empty = ClassicalMetadata(
        work: nil, workID: nil, ensemble: nil,
        composer: nil, conductor: nil, recordingYear: nil,
        soloist: nil, section: nil, workID_slug: nil
    )
}

// Codable so Track (which is Codable) can include this field without breaking
// PlaybackStateStore queue persistence. Auto-synthesized: all members are
// Optional primitives.
extension ClassicalMetadata: Codable {}
