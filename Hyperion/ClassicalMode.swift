import Foundation
import SwiftUI

// MARK: - Classical mode gate
//
// Single source of truth for whether classical content is surfaced anywhere
// in the app. Views observe it via @AppStorage(ClassicalMode.defaultsKey);
// non-view code (mix generation, radio replenishment) reads ClassicalMode.isEnabled.
//
// Default is ON: an existing library keeps its classical content visible until
// the user opts out in Settings.

enum ClassicalMode {
    static let defaultsKey = "hyperion.classical.enabled"

    /// Non-view accessor. Mirrors the @AppStorage default (true when unset).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: defaultsKey)
    }
}

// MARK: - Classical content classification
//
// Used to keep classical tracks out of non-classical suggestion/radio results
// when classical mode is off. Deliberately conservative: if classical metadata
// has not been resolved yet, a track is treated as NON-classical (better to
// occasionally include a classical track than to wrongly block pop tracks).

extension Track {
    /// True when this track should be treated as classical for filtering.
    /// Matches the Stage-4 rule:
    ///   classicalMetadata?.work != nil
    ///   OR (composer != nil AND genre contains a classical keyword)
    var looksClassical: Bool {
        if classicalMetadata?.work != nil { return true }
        guard let composer, !composer.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        guard let genres, !genres.isEmpty else { return false }
        let folded = genres.lowercased()
        return ClassicalMode.classicalGenreKeywords.contains { folded.contains($0) }
    }
}

extension Album {
    /// True when an album should be treated as a (purely) classical release for
    /// gating ambiguous album grids. Uses the server's isClassical flag, falling
    /// back to "has a composer credit" — the same heuristic Home used previously.
    var looksClassical: Bool {
        if isClassical == 1 { return true }
        if let composer, !composer.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return false
    }
}

extension ClassicalMode {
    /// Lowercased substrings that mark a genre string as classical.
    static let classicalGenreKeywords: [String] = [
        "classical", "baroque", "romantic", "renaissance", "medieval",
        "opera", "operatic", "symphony", "symphonic", "concerto",
        "chamber", "orchestral", "choral", "oratorio", "early music",
        "contemporary classical", "20th century classical"
    ]
}

// MARK: - Canonical Home ⇄ Classical data split
//
// The Home tab and the Classical tab draw from COMPLETELY separate data: they
// must never share play history, recommendations, or library entries.
//
// The single rule for the split — applied at the repository layer
// (PlaybackHistoryStore, LibraryViewModel) so no view ever re-derives it — is:
//
//     content is "classical" when its LMS genre tag contains the substring
//     "classical" (case- and diacritic-insensitive).
//
// This is intentionally distinct from `looksClassical` above, which drives the
// optional, broader "classical mode" gate (baroque/opera/etc.). The data split
// keys strictly off the genre tag the user asked for, with a conservative
// fallback to the server `isClassical` flag / composer credit only where a
// genre tag is not present on the object (LMS album rows rarely carry one).

/// Which slice of the library a view should receive.
enum LibraryContentScope {
    case all          // Library tab — everything
    case nonClassical // Home tab
    case classical    // Classical tab
}

extension ClassicalMode {
    /// Canonical genre rule. A comma-separated multi-genre string is classical
    /// when ANY component contains "classical".
    static func genreIsClassical(_ genres: String?) -> Bool {
        guard let genres, !genres.isEmpty else { return false }
        return genres.range(
            of: "classical",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}

extension Track {
    /// Repository-layer split: true when this track belongs to the Classical
    /// tab and must be kept off Home. Genre-tag first, then server flags.
    var isClassicalContent: Bool {
        if ClassicalMode.genreIsClassical(genres) { return true }
        if isClassical == 1 { return true }
        if classicalMetadata?.work != nil { return true }
        return false
    }
}

extension Album {
    /// Repository-layer split for albums. LMS album rows seldom carry a genre
    /// tag, so this falls back to the server `isClassical` flag and a composer
    /// credit when `genres` is absent.
    var isClassicalContent: Bool {
        if ClassicalMode.genreIsClassical(genres) { return true }
        if isClassical == 1 { return true }
        if let composer, !composer.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return false
    }
}

extension Genre {
    /// True for genres whose name marks them as classical (e.g. "Classical",
    /// "Modern Classical"). Used to keep the Home genres rail non-classical.
    var isClassicalContent: Bool { ClassicalMode.genreIsClassical(name) }
}
