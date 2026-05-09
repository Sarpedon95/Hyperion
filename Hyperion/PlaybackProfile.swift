import Foundation

// MARK: - Crossfade shape

enum CrossfadeShape: String, Codable, CaseIterable, Identifiable {
    case linear     = "Linear"
    case equalPower = "Equal Power"
    case sCurve     = "S-Curve"

    var id: String { rawValue }

    /// Returns the gain (0–1) for a given normalised position `t` (0–1).
    /// `fadingOut` = true for the outgoing stream, false for the incoming stream.
    func gain(t: Float, fadingOut: Bool) -> Float {
        switch self {
        case .linear:
            return fadingOut ? max(0, 1 - t) : min(1, t)
        case .equalPower:
            return fadingOut ? cos(t * .pi / 2) : sin(t * .pi / 2)
        case .sCurve:
            return fadingOut ? Float((1 + cos(Double(t) * .pi)) / 2)
                             : Float((1 - cos(Double(t) * .pi)) / 2)
        }
    }
}

// MARK: - Crossfeed (BS2B) presets

/// Standard Bauer stereophonic-to-binaural coefficient sets.
/// `strength` is the linear cross-channel mix factor (0–1).
/// `cutoffHz` is the 1-pole IIR low-pass cutoff for the cross-channel signal.
enum CrossfeedPreset: String, Codable, CaseIterable, Identifiable {
    case light    = "Light"
    case moderate = "Moderate"
    case strong   = "Strong"

    var id: String { rawValue }

    var strength:  Float {
        switch self {
        case .light:    return 0.30
        case .moderate: return 0.45
        case .strong:   return 0.60
        }
    }

    var cutoffHz: Float {
        switch self {
        case .light:    return 700
        case .moderate: return 700
        case .strong:   return 650
        }
    }

    var delayMs: Float { 0.3 }

    var feedLevelDescription: String {
        switch self {
        case .light:    return "3.0 dB feed · 700 Hz"
        case .moderate: return "4.5 dB feed · 700 Hz"
        case .strong:   return "6.0 dB feed · 650 Hz"
        }
    }
}

// MARK: - Inter-track gap (only meaningful when gapless is disabled)

enum InterTrackGap: Double, Codable, CaseIterable, Identifiable {
    case none   = 0.0
    case short  = 1.0
    case medium = 2.0

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .none:   return "None"
        case .short:  return "1 second"
        case .medium: return "2 seconds"
        }
    }
}

// MARK: - Playback profile

/// Multi-genre playback profile that drives gapless, crossfade, crossfeed, and gap defaults.
enum PlaybackProfile: String, Codable, CaseIterable, Identifiable {
    case classical  = "classical"
    case electronic = "electronic"
    case standard   = "standard"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classical:  return "Classical"
        case .electronic: return "Electronic"
        case .standard:   return "Standard"
        }
    }

    // Gapless is always on by default across all profiles.
    var defaultGaplessEnabled: Bool { true }

    var defaultCrossfadeEnabled: Bool {
        switch self {
        case .electronic: return true
        default:          return false
        }
    }

    var defaultCrossfadeDuration: TimeInterval {
        switch self {
        case .electronic: return 2.5
        default:          return 0.0
        }
    }

    var defaultCrossfeedEnabled: Bool {
        switch self {
        case .classical: return true
        default:         return false
        }
    }

    var defaultCrossfeedPreset: CrossfeedPreset {
        switch self {
        case .classical: return .moderate
        default:         return .light
        }
    }

    var defaultInterTrackGap: InterTrackGap { .none }

    // MARK: - Genre auto-detection

    private static let classicalKeywords: [String] = [
        "classical", "opera", "chamber", "orchestral", "baroque", "romantic",
        "contemporary classical", "choral", "symphony", "chamber music",
        "early music", "renaissance", "medieval", "neoclassical",
        "modern classical", "20th century classical", "impressionist",
        "contemporary", "avant-garde classical"
    ]

    private static let electronicKeywords: [String] = [
        "electronic", "dance", "techno", "house", "trance", "ambient",
        "edm", "pop", "hip-hop", "hip hop", "r&b", "rnb", "funk", "soul",
        "disco", "idm", "dubstep", "drum and bass", "dnb", "synthpop",
        "electronica", "new wave", "synth", "industrial", "trap", "reggaeton"
    ]

    static func autoDetect(from genres: String?) -> PlaybackProfile {
        guard let genres, !genres.isEmpty else { return .standard }
        let parts = genres.lowercased()
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for part in parts {
            if classicalKeywords.contains(where: { part.contains($0) || $0.contains(part) }) {
                return .classical
            }
        }
        for part in parts {
            if electronicKeywords.contains(where: { part.contains($0) || $0.contains(part) }) {
                return .electronic
            }
        }
        return .standard
    }
}

// MARK: - Detection source

enum ProfileDetectionSource: Equatable {
    case auto
    case manual
    case globalDefault

    var label: String {
        switch self {
        case .auto:          return "auto"
        case .manual:        return "manual"
        case .globalDefault: return ""
        }
    }
}

// MARK: - Per-profile stored settings

struct ProfileSettings: Codable {
    var gaplessEnabled:              Bool
    var crossfadeEnabled:            Bool
    var crossfadeDuration:           Double
    var crossfadeShape:              CrossfadeShape
    var crossfeedEnabled:            Bool
    var crossfeedPreset:             CrossfeedPreset
    var interTrackGap:               InterTrackGap
    var sampleRateConversionEnabled: Bool = true

    static func defaults(for profile: PlaybackProfile) -> ProfileSettings {
        ProfileSettings(
            gaplessEnabled:              profile.defaultGaplessEnabled,
            crossfadeEnabled:            profile.defaultCrossfadeEnabled,
            crossfadeDuration:           profile.defaultCrossfadeDuration,
            crossfadeShape:              .equalPower,
            crossfeedEnabled:            profile.defaultCrossfeedEnabled,
            crossfeedPreset:             profile.defaultCrossfeedPreset,
            interTrackGap:               profile.defaultInterTrackGap,
            sampleRateConversionEnabled: true
        )
    }
}
