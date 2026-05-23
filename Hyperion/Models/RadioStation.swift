import Foundation

// MARK: - Radio station
//
// An internet radio station from RadioBrowser (or a hardcoded featured seed).
// This is the internet-radio feature (Radio tab), distinct from the existing
// auto-DJ "radio session" (PlayerViewModel.isRadioEnabled) that replenishes a
// track queue with similar songs.

struct RadioStation: Identifiable, Hashable, Codable {
    let id: String          // stationuuid from RadioBrowser (or a seed slug for featured)
    let name: String
    let streamURL: URL
    let genre: String?      // first tag from RadioBrowser's comma-separated tags
    let country: String?
    let language: String?
    let logoURL: URL?       // favicon field
    let bitrate: Int?       // bitrate field
    let codec: String?      // codec field
    let votes: Int?         // votes field (popularity)
    let isFeatured: Bool    // true for hardcoded featured stations only

    // Display helpers
    var bitrateDisplay: String? {
        guard let b = bitrate, b > 0 else { return nil }
        return "\(b) kbps"
    }

    var qualityLabel: String? {
        guard let b = bitrate else { return nil }
        if b >= 320 { return "Hi" }
        if b >= 128 { return "Mid" }
        return nil
    }

    /// "Genre · Country · 128 kbps" — compact one-line detail for list rows.
    var detailLine: String {
        [genre, country, bitrateDisplay]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Two-letter initials for a logo placeholder.
    var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        if let first = words.first?.first {
            if words.count >= 2, let second = words[1].first {
                return String([first, second]).uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }
        return "?"
    }
}

// MARK: - Radio playback constants

enum RadioPlayback {
    /// Sentinel track id reserved for radio so any code that inspects a Track id
    /// can recognise a radio stream. The dedicated radio path keeps currentTrack
    /// nil, but this is available if a synthetic Track is ever needed.
    static let syntheticTrackID = -987_654_321
}

// MARK: - Radio tab gate
//
// Mirrors ClassicalMode: the Radio tab is optional, toggled in Settings.
// Default OFF so the internet-radio feature is opt-in.

enum RadioMode {
    static let defaultsKey = "hyperion.radioTab.enabled"

    /// Non-view accessor. Mirrors the @AppStorage default (false when unset).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
