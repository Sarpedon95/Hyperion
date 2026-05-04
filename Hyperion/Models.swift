import Foundation
import SwiftUI

struct Track: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let album: String?
    let albumID: Int?
    let albumartist: String?
    let composer: String?
    let trackartist: String?
    let work: String?
    let duration: Double?
    let tracknum: Int?
    let discnum: Int?
    let year: Int?
    let coverid: String?
    let url: String?
    let genres: String?
    let isClassical: Int?

    // Equality on id so mid-session tag changes don't break queue lookups.
    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var durationFormatted: String {
        TimeFormatting.formatDuration(duration)
    }

    func withAlbumIDIfMissing(_ fallbackAlbumID: Int?) -> Track {
        guard albumID == nil, let fallbackAlbumID else { return self }
        return Track(
            id:          id,
            title:       title,
            album:       album,
            albumID:     fallbackAlbumID,
            albumartist: albumartist,
            composer:    composer,
            trackartist: trackartist,
            work:        work,
            duration:    duration,
            tracknum:    tracknum,
            discnum:     discnum,
            year:        year,
            coverid:     coverid,
            url:         url,
            genres:      genres,
            isClassical: isClassical
        )
    }
}

struct Work: Identifiable, Hashable, Codable {
    let work_id: Int
    let work: String
    let composer: String?
    let composer_id: Int?
    let album_id: String?
    let artwork_track_id: String?

    // BUGFIX: work_id <= 0 is possible for fabricated Work objects in search.
    // Return a stable String id to prevent ForEach collisions.
    var id: String {
        work_id > 0
            ? String(work_id)
            : "\(work)|\(composer ?? "")|\(album_id ?? "")"
    }
}

struct Album: Identifiable, Hashable, Codable {
    let id: Int
    let album: String
    let artist: String?
    let year: Int?
    let artwork_track_id: String?
    let composer: String?
    let isClassical: Int?
}

struct Composer: Identifiable, Hashable, Codable {
    let id: Int
    let artist: String

    var displayName: String { artist }
}

struct WorkGroup: Identifiable, Hashable, Codable {
    let id: Int
    let workTitle: String
    let composer: String?
    let tracks: [Track]
    let coverid: String?

    var totalDuration: Double {
        tracks.compactMap(\.duration).reduce(0, +)
    }

    var totalDurationFormatted: String {
        TimeFormatting.formatDuration(totalDuration)
    }
}


// MARK: - Time formatting

/// Single canonical duration formatter for every label in the app.
/// "M:SS" under one hour; "H:MM:SS" at one hour or more.
enum TimeFormatting {
    static func formatDuration(_ seconds: Double?, placeholder: String = "") -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return placeholder }
        let total   = Int(seconds)
        let hours   = total / 3600
        let minutes = (total % 3600) / 60
        let secs    = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Audio format classification

/// Canonical set of lossless audio file extensions used throughout the app.
/// Declared once here to avoid divergent inline `Set<String>` literals
/// in LyrionAPI, PlayerViewModel, NowPlayingView, and Models.
enum AudioFormats {
    /// Uppercase extensions that represent lossless audio containers.
    /// Used for bit-perfect detection, quality-pill colour, and signal-path display.
    static let lossless: Set<String> = ["FLAC", "WAV", "ALAC", "AIFF", "AIF", "APE", "WV"]

    /// Same as `lossless` but lowercased, for matching against LMS `type` fields
    /// (which LMS returns in lowercase, e.g. "flac", "alac", "wav").
    static let losslessLowercase: Set<String> = ["flac", "wav", "alac", "aiff", "aif", "ape", "wv"]

    static func isLossless(_ ext: String) -> Bool {
        lossless.contains(ext.uppercased())
    }
}


// MARK: - Search text normalization

/// Locale-stable, diacritic-insensitive matching used throughout the app.
enum SearchTextNormalizer {
    // FIX: pin to POSIX locale to avoid Turkish-i casing surprises on any device.
    private static let stableLocale = Locale(identifier: "en_US_POSIX")

    static func folded(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: stableLocale)
            .lowercased(with: stableLocale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(from value: String) -> [String] {
        folded(value)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func matches(_ text: String, query: String) -> Bool {
        let foldedQuery = folded(query)
        guard !foldedQuery.isEmpty else { return true }
        return matchesFoldedQuery(text, foldedQuery: foldedQuery, tokens: tokens(from: query))
    }

    static func matchesFoldedQuery(_ text: String, foldedQuery: String, tokens: [String]) -> Bool {
        let foldedText = folded(text)
        if foldedText.contains(foldedQuery) { return true }
        guard tokens.count > 1 else { return false }
        return tokens.allSatisfy { foldedText.contains($0) }
    }

    /// Pre-normalized query; build once per keystroke, call matches(_:) per item.
    struct Needle: Equatable {
        let folded: String
        let tokens: [String]

        static let empty = Needle("")

        init(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            self.folded = SearchTextNormalizer.folded(trimmed)
            self.tokens = SearchTextNormalizer.tokens(from: trimmed)
        }

        var isEmpty: Bool { folded.isEmpty }

        func matches(_ text: String) -> Bool {
            SearchTextNormalizer.matchesFoldedQuery(text, foldedQuery: folded, tokens: tokens)
        }
    }
}


struct QueueWorkGroup: Identifiable, Hashable {
    struct QueueTrackItem: Hashable {
        let index: Int
        let track: Track
    }

    let id: Int
    let workTitle: String
    let composer: String?
    let tracks: [QueueTrackItem]
}

enum ConnectionMode: String, CaseIterable {
    case auto      = "Auto"
    case local     = "Local"
    case tailscale = "Tailscale"
    case proxy     = "Proxy (Nginx)"

    var displayName: String {
        switch self {
        case .auto:      return "Auto"
        case .local:     return "Home LAN"
        case .tailscale: return "Tailscale"
        case .proxy:     return "Remote Proxy"
        }
    }
}


// MARK: - Audio Signal Path

enum QualityStatus: Equatable, Hashable {
    case lossless
    case enhanced
    case converted
    case limited
    case unknown

    var displayLabel: String {
        switch self {
        case .lossless:   return "Lossless"
        case .enhanced:   return "Enhanced"
        case .converted:  return "Converted"
        case .limited:    return "Limited"
        case .unknown:    return "Unknown"
        }
    }

    var tintColor: Color {
        switch self {
        case .lossless:   return Color(red: 0.2, green: 0.85, blue: 0.4)  // green
        case .enhanced:   return Color(hex: "#7b6cf6")                     // purple
        case .converted:  return Color(red: 0.95, green: 0.75, blue: 0.2) // amber
        case .limited:    return Color.red
        case .unknown:    return Color.roonTertiary
        }
    }

    /// Severity for badge color selection; higher is worse.
    var severity: Int {
        switch self {
        case .lossless:   return 0
        case .enhanced:   return 1
        case .converted:  return 2
        case .limited:    return 3
        case .unknown:    return 4
        }
    }
}

struct AudioPathStep: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let status: QualityStatus

    init(icon: String, title: String, subtitle: String, status: QualityStatus) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.id = "\(icon)|\(title)|\(subtitle)|\(status.displayLabel)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioPathStep, rhs: AudioPathStep) -> Bool {
        lhs.id == rhs.id
    }
}

struct AudioSignalPath: Identifiable, Hashable {
    let id: UUID = UUID()
    let steps: [AudioPathStep]

    var worstStatus: QualityStatus {
        steps.max(by: { $0.status.severity < $1.status.severity })?.status ?? .unknown
    }

    var badgeLabel: String {
        worstStatus.displayLabel
    }

    /// Generate a signal path from track metadata (fallback/mock).
    static func from(track: Track, isBitPerfect: Bool = true) -> AudioSignalPath {
        var steps: [AudioPathStep] = []

        // Source
        if let url = track.url, !url.isEmpty {
            let format = audioFormatFromURL(url)
            let isLosslessFormat = AudioFormats.isLossless(format)
            steps.append(AudioPathStep(
                icon: "opticaldisc",
                title: "Source",
                subtitle: format,
                status: isLosslessFormat ? .lossless : .converted
            ))
        }

        // Streaming
        steps.append(AudioPathStep(
            icon: "network",
            title: "Streaming",
            subtitle: "Lyrion Music Server (HTTP)",
            status: .lossless
        ))

        // Decoder
        if let url = track.url {
            let format = audioFormatFromURL(url)
            let isBitPerfectFormat = AudioFormats.isLossless(format)
            steps.append(AudioPathStep(
                icon: "arrowtriangle.right.fill",
                title: "Decoding",
                subtitle: isBitPerfectFormat ? "\(format) → PCM (no conversion)" : "\(format) → PCM",
                status: isBitPerfectFormat ? .lossless : .converted
            ))
        }

        // Bit Depth
        steps.append(AudioPathStep(
            icon: "waveform.circle",
            title: "Bit Depth",
            subtitle: "16-bit (from source metadata)",
            status: .lossless
        ))

        // Sample Rate
        steps.append(AudioPathStep(
            icon: "waveform.circle",
            title: "Sample Rate",
            subtitle: "44.1 kHz (no resampling)",
            status: .lossless
        ))

        // Processing / DSP
        steps.append(AudioPathStep(
            icon: "slider.horizontal.3",
            title: "Processing",
            subtitle: "None (bit-perfect mode)",
            status: isBitPerfect ? .lossless : .limited
        ))

        // Headroom
        steps.append(AudioPathStep(
            icon: "speaker.wave.2",
            title: "Headroom",
            subtitle: "0 dB (full scale)",
            status: isBitPerfect ? .enhanced : .limited
        ))

        // Output
        let isWiredOutput = true
        steps.append(AudioPathStep(
            icon: "headphones",
            title: "Output",
            subtitle: isWiredOutput ? "Headphones (Stereo)" : "Bluetooth (Stereo)",
            status: isWiredOutput ? .lossless : .converted
        ))

        return AudioSignalPath(steps: steps)
    }

    /// Generate a real-time signal path from actual playback state.
    /// This uses live AVAudioSession data, not track metadata.
    static func fromPlaybackState(
        track: Track,
        sourceFormat: String,
        outputFormat: String,
        isBitPerfect: Bool,
        volume: Float = 1.0,
        lmsQuality: LMSAudioQuality? = nil
    ) -> AudioSignalPath {
        var steps: [AudioPathStep] = []

        // 1. Source file format
        let sourceParts = sourceFormat.split(separator: " ")
        let sourceExt = String(sourceParts.first ?? "Unknown")
        let isSourceLossless = AudioFormats.isLossless(sourceExt)

        steps.append(AudioPathStep(
            icon: "opticaldisc",
            title: "Source",
            subtitle: sourceExt,
            status: isSourceLossless ? .lossless : .converted
        ))

        // 2. Streaming path
        steps.append(AudioPathStep(
            icon: "network",
            title: "Streaming",
            subtitle: "Lyrion Music Server",
            status: .lossless
        ))

        // 3. Decoding
        let decoderStatus: QualityStatus = isSourceLossless ? .lossless : .converted
        let decoderSubtitle = isSourceLossless ? "Lossless decode" : "Lossy decode"
        steps.append(AudioPathStep(
            icon: "arrowtriangle.right.fill",
            title: "Decode",
            subtitle: decoderSubtitle,
            status: decoderStatus
        ))

        // 4. Bit depth — use live LMS data when available; otherwise omit
        //    (we cannot infer it reliably from the container format alone).
        if let lmsQ = lmsQuality, lmsQ.sampleSize > 0 {
            steps.append(AudioPathStep(
                icon: "waveform.circle",
                title: "Bit Depth",
                subtitle: "\(lmsQ.sampleSize)-bit",
                status: .lossless
            ))
        }

        // 5. Sample Rate — prefer LMS-reported rate; fall back to AVAudioSession.
        let sampleRateStr: String
        let needsResampling: Bool
        if let lmsQ = lmsQuality, lmsQ.sampleRate > 0 {
            let khz = Double(lmsQ.sampleRate) / 1000
            sampleRateStr = String(format: khz.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f kHz" : "%.1f kHz", khz)
            // Resampling occurs when AVAudioSession output rate differs from source.
            // extractSampleRate returns strings like "44.1 kHz" or "48.0 kHz".
            let sessionRateStr = extractSampleRate(from: outputFormat)
            needsResampling = sessionRateStr != sampleRateStr
        } else {
            sampleRateStr = extractSampleRate(from: outputFormat)
            needsResampling = sourceNeedsResampling(sourceExt, targetRate: sampleRateStr)
        }

        steps.append(AudioPathStep(
            icon: "waveform.circle",
            title: "Sample Rate",
            subtitle: sampleRateStr,
            status: needsResampling ? .converted : .enhanced
        ))

        // 6. Volume Processing
        let volumePercent = Int(volume * 100)
        let volumeLabel = volumePercent == 100 ? "Full scale" : "\(volumePercent)%"
        steps.append(AudioPathStep(
            icon: "speaker.wave.2",
            title: "Volume",
            subtitle: volumeLabel,
            status: volumePercent >= 90 ? .enhanced : (volumePercent >= 50 ? .lossless : .converted)
        ))

        // 7. Output device (from outputFormat)
        let (deviceName, deviceIsLossless) = extractDeviceInfo(from: outputFormat)
        let outputStatus: QualityStatus = deviceIsLossless ? .lossless : .converted

        steps.append(AudioPathStep(
            icon: "headphones",
            title: "Output",
            subtitle: deviceName,
            status: outputStatus
        ))

        // 8. Overall quality verification
        if isBitPerfect && isSourceLossless && deviceIsLossless && !needsResampling {
            steps.append(AudioPathStep(
                icon: "checkmark.circle.fill",
                title: "Verification",
                subtitle: "Bit-perfect end-to-end",
                status: .lossless
            ))
        }

        return AudioSignalPath(steps: steps)
    }

    private static func bitDepthFromFormat(_ format: String) -> Int? {
        // For lossy formats, bit depth is not meaningful (the original PCM
        // depth is discarded during encoding). For lossless containers we
        // cannot infer depth from format alone (FLAC can be 16 or 24-bit),
        // so we return nil and let the signal-path skip this step rather than
        // show a wrong value. Callers that have live LMS samplesize data should
        // build the step themselves.
        return nil
    }

    private static func sourceNeedsResampling(_ format: String, targetRate: String) -> Bool {
        // Without live LMS samplerate data we can only make a rough guess.
        // Most lossless libraries are 44.1 kHz (CD) or 48 kHz (studio).
        // If the AVAudioSession output rate is neither, flag as a possible
        // resample — conservative (may show false positives for 96 kHz output
        // with a 44.1 kHz source) but better than always claiming no resampling.
        let isCommonRate = targetRate.contains("44.1") || targetRate.contains("48")
        return !isCommonRate && AudioFormats.isLossless(format)
    }

    private static func extractSampleRate(from outputFormat: String) -> String {
        // outputFormat looks like "Headphones (48000 Hz, 2ch)"
        // Match " Hz" (with leading space) to avoid accidentally matching an
        // "H" in a device name like "HiFi BT" or "Honor earbuds".
        if let start = outputFormat.firstIndex(of: "("),
           let hzRange = outputFormat.range(of: " Hz"),
           hzRange.lowerBound > start {
            let range = outputFormat.index(after: start)..<hzRange.lowerBound
            let rate = String(outputFormat[range]).trimmingCharacters(in: .whitespaces)
            if let hz = Int(rate) {
                if hz == 48000 {
                    return "48.0 kHz"
                } else if hz == 44100 {
                    return "44.1 kHz"
                } else if hz == 96000 {
                    return "96.0 kHz"
                } else {
                    return "\(Double(hz) / 1000) kHz"
                }
            }
        }
        return "Unknown"
    }

    private static func extractDeviceInfo(from outputFormat: String) -> (name: String, isLossless: Bool) {
        // outputFormat looks like "Headphones (48000 Hz, 2ch)"
        if let closeIdx = outputFormat.firstIndex(of: "(") {
            let device = String(outputFormat[..<closeIdx]).trimmingCharacters(in: .whitespaces)
            let isLossless = !device.lowercased().contains("bluetooth") &&
                            !device.lowercased().contains("airplay")
            return (device, isLossless)
        }
        return ("Unknown", false)
    }

    private static func audioFormatFromURL(_ url: String) -> String {
        if let u = URL(string: url), !u.pathExtension.isEmpty {
            return u.pathExtension.uppercased()
        }
        return "Unknown"
    }

    static let mockPath = AudioSignalPath(
        steps: [
            AudioPathStep(
                icon: "network",
                title: "Source",
                subtitle: "Lyrion Music Server",
                status: .lossless
            ),
            AudioPathStep(
                icon: "arrowtriangle.right.fill",
                title: "Streaming",
                subtitle: "Direct stream (flac)",
                status: .lossless
            ),
            AudioPathStep(
                icon: "waveform.circle",
                title: "Bit Depth",
                subtitle: "24-bit (no conversion)",
                status: .lossless
            ),
            AudioPathStep(
                icon: "waveform.circle",
                title: "Sample Rate",
                subtitle: "44.1 kHz (no conversion)",
                status: .lossless
            ),
            AudioPathStep(
                icon: "speaker.wave.2",
                title: "Headroom",
                subtitle: "6 dB available",
                status: .enhanced
            ),
            AudioPathStep(
                icon: "slider.horizontal.3",
                title: "Volume",
                subtitle: "No normalization",
                status: .lossless
            ),
            AudioPathStep(
                icon: "headphones",
                title: "Output",
                subtitle: "Headphones (stereo)",
                status: .lossless
            )
        ]
    )
}
