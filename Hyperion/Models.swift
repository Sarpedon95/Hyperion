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

    // Audio metadata reported by LMS/Lyrion when requested with songinfo/status tags.
    // These are optional on purpose: absence means "not reported," not a fallback claim.
    let audioType: String?
    let sampleRate: Int?
    let sampleSize: Int?
    let bitrate: String?
    let lossless: Bool?
    let replayGain: Double?
    let albumReplayGain: Double?
    let isRemote: Bool?

    // Populated lazily by ClassicalMetadataResolver when a track is needed
    // for display or playback. Nil for non-classical tracks and for tracks
    // whose metadata has not been resolved yet.
    var classicalMetadata: ClassicalMetadata? = nil

    init(
        id: Int,
        title: String,
        album: String?,
        albumID: Int?,
        albumartist: String?,
        composer: String?,
        trackartist: String?,
        work: String?,
        duration: Double?,
        tracknum: Int?,
        discnum: Int?,
        year: Int?,
        coverid: String?,
        url: String?,
        genres: String?,
        isClassical: Int?,
        audioType: String? = nil,
        sampleRate: Int? = nil,
        sampleSize: Int? = nil,
        bitrate: String? = nil,
        lossless: Bool? = nil,
        replayGain: Double? = nil,
        albumReplayGain: Double? = nil,
        isRemote: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.albumID = albumID
        self.albumartist = albumartist
        self.composer = composer
        self.trackartist = trackartist
        self.work = work
        self.duration = duration
        self.tracknum = tracknum
        self.discnum = discnum
        self.year = year
        self.coverid = coverid
        self.url = url
        self.genres = genres
        self.isClassical = isClassical
        self.audioType = audioType
        self.sampleRate = sampleRate
        self.sampleSize = sampleSize
        self.bitrate = bitrate
        self.lossless = lossless
        self.replayGain = replayGain
        self.albumReplayGain = albumReplayGain
        self.isRemote = isRemote
    }

    // Equality on id so mid-session tag changes don't break queue lookups.
    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var durationFormatted: String {
        TimeFormatting.formatDuration(duration)
    }

    func withAlbumIDIfMissing(_ fallbackAlbumID: Int?) -> Track {
        guard albumID == nil, let fallbackAlbumID else { return self }
        var copy = Track(
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
            isClassical: isClassical,
            audioType: audioType,
            sampleRate: sampleRate,
            sampleSize: sampleSize,
            bitrate: bitrate,
            lossless: lossless,
            replayGain: replayGain,
            albumReplayGain: albumReplayGain,
            isRemote: isRemote
        )
        copy.classicalMetadata = classicalMetadata
        return copy
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
    let conductor: String?
    let band: String?
    let dynamicRange: Int?

    init(id: Int, album: String, artist: String?, year: Int?,
         artwork_track_id: String?, composer: String?, isClassical: Int?,
         conductor: String? = nil, band: String? = nil, dynamicRange: Int? = nil) {
        self.id = id; self.album = album; self.artist = artist; self.year = year
        self.artwork_track_id = artwork_track_id; self.composer = composer
        self.isClassical = isClassical; self.conductor = conductor
        self.band = band; self.dynamicRange = dynamicRange
    }
}

struct Composer: Identifiable, Hashable, Codable {
    let id: Int
    let artist: String

    var displayName: String { artist }
}

struct Artist: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
}

struct Genre: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
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

    /// True when grouping fell back to "this album/playlist as one bucket".
    /// UI renders these as normal track lists so non-classical releases do not
    /// get fake work headers.
    var isFlatFallbackGroup: Bool {
        let noNativeWorkTags = tracks.allSatisfy { ($0.work ?? "").isEmpty }
        guard noNativeWorkTags else { return false }
        if SearchTextNormalizer.folded(workTitle) == "tracks" { return true }
        guard let firstAlbum = tracks.first?.album, !firstAlbum.isEmpty else { return false }
        return SearchTextNormalizer.folded(workTitle) == SearchTextNormalizer.folded(firstAlbum)
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

    /// Same as `lossless` but lowercased, for matching against LMS `type` fields.
    /// IMPORTANT: LMS uses abbreviated internal codec codes that differ from file
    /// extensions — "flc" for FLAC, "alc" for ALAC. Both must be listed here so
    /// that isLosslessCodec() correctly classifies LMS-reported types.
    static let losslessLowercase: Set<String> = [
        "flac", "flc",       // FLAC: canonical ext + LMS internal code
        "alac", "alc",       // ALAC: canonical ext + LMS internal code
        "wav", "wave",
        "aiff", "aif",
        "ape", "wv",
    ]

    /// Lowercase codecs/containers where the source is known to be perceptually coded.
    static let lossyLowercase: Set<String> = ["mp3", "aac", "m4a", "m4b", "ogg", "opus", "wma", "wmap", "mp4"]

    /// Maps LMS-internal codec codes to their canonical file extensions.
    ///
    /// LMS returns abbreviated type codes in the `type` field (e.g. "flc", "aif")
    /// that do NOT match the file extension in stream URLs ("flac", "aiff"). Without
    /// this mapping, comparing sourceExt == streamExt produces a false "Transcoded?"
    /// result for every lossless file.
    private static let lmsCodecExtensionMap: [String: String] = [
        "flc":  "flac",   // FLAC
        "alc":  "alac",   // ALAC (some LMS builds)
        "aif":  "aiff",   // AIFF (LMS drops the trailing 'f')
        "pcm":  "wav",    // Raw PCM is served/stored as WAV
    ]

    /// Returns the canonical file extension for an LMS `type` codec code,
    /// falling back to the value unchanged when no mapping exists.
    /// Apply to BOTH sides of any codec ↔ extension comparison.
    static func canonicalExtension(forLMSCodec codec: String) -> String {
        let lower = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lmsCodecExtensionMap[lower] ?? lower
    }

    static func isLossless(_ ext: String) -> Bool {
        lossless.contains(ext.uppercased())
    }

    static func isLosslessCodec(_ codec: String) -> Bool {
        losslessLowercase.contains(codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func isLossyCodec(_ codec: String) -> Bool {
        lossyLowercase.contains(codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
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
        case .lossless:   return "Direct"
        case .enhanced:   return "Processed"
        case .converted:  return "Changed"
        case .limited:    return "Limited"
        case .unknown:    return "Unknown"
        }
    }

    var tintColor: Color {
        switch self {
        case .lossless:   return Color(red: 0.2, green: 0.85, blue: 0.4)
        case .enhanced:   return Color(hex: "#7b6cf6")
        case .converted:  return Color(red: 0.95, green: 0.75, blue: 0.2)
        case .limited:    return Color.red
        case .unknown:    return Color.roonTertiary
        }
    }

    /// Severity for badge color selection; higher is worse.
    var severity: Int {
        switch self {
        case .lossless:   return 0
        case .enhanced:   return 1
        case .unknown:    return 2
        case .converted:  return 3
        case .limited:    return 4
        }
    }
}

enum SignalPathConfidence: String, Hashable {
    case verified
    case reported
    case configured
    case unverified
    case unknown

    var label: String {
        switch self {
        case .verified:   return "Verified"
        case .reported:   return "Reported"
        case .configured: return "Configured"
        case .unverified: return "Unverified"
        case .unknown:    return "Unknown"
        }
    }
}

struct SignalPathDiagnostics: Hashable {
    var rawTrackFields: [String: String] = [:]
    var rawStatusFields: [String: String] = [:]
    var usedFields: [String] = []
    var missingFields: [String] = []
    var notes: [String] = []

    var hasContent: Bool {
        !rawTrackFields.isEmpty || !rawStatusFields.isEmpty || !usedFields.isEmpty || !missingFields.isEmpty || !notes.isEmpty
    }
}

struct OrpheusSignalPathItem: Identifiable, Hashable {
    let id: String
    let title: String
    let technicalValue: String
    let explanation: String

    init(title: String, technicalValue: String, explanation: String) {
        self.title = title
        self.technicalValue = technicalValue
        self.explanation = explanation
        self.id = "\(title)|\(technicalValue)"
    }
}

struct OrpheusSignalPathState: Hashable {
    let isPlaybackRoutedThroughOrpheus: Bool
    let isPureModeEnabled: Bool
    let activePresetName: String?
    let activeItems: [OrpheusSignalPathItem]
    let configuredOnlyItems: [OrpheusSignalPathItem]
    let inactiveItems: [String]

    var hasAnyConfiguredProcessing: Bool {
        !activeItems.isEmpty || !configuredOnlyItems.isEmpty
    }
}

struct AudioPathStep: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let status: QualityStatus
    let statusLabel: String
    let confidence: SignalPathConfidence
    let technicalValue: String?
    let explanation: String
    let sourceOfTruth: String
    let usedFields: [String]
    let missingFields: [String]

    init(
        id: String? = nil,
        icon: String,
        title: String,
        subtitle: String,
        status: QualityStatus,
        statusLabel: String? = nil,
        confidence: SignalPathConfidence = .unknown,
        technicalValue: String? = nil,
        explanation: String = "",
        sourceOfTruth: String = "Not reported",
        usedFields: [String] = [],
        missingFields: [String] = []
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.statusLabel = statusLabel ?? status.displayLabel
        self.confidence = confidence
        self.technicalValue = technicalValue
        self.explanation = explanation
        self.sourceOfTruth = sourceOfTruth
        self.usedFields = usedFields
        self.missingFields = missingFields
        self.id = id ?? "\(icon)|\(title)|\(subtitle)|\(self.statusLabel)|\(confidence.rawValue)"
    }
}

struct AudioSignalPath: Identifiable, Hashable {
    let id: UUID = UUID()
    let steps: [AudioPathStep]
    let badgeStatus: QualityStatus
    let badgeLabelOverride: String
    let diagnostics: SignalPathDiagnostics
    let whyNotBitPerfect: [String]

    var worstStatus: QualityStatus { badgeStatus }
    var badgeLabel: String { badgeLabelOverride }
    var isVerifiedBitPerfect: Bool { badgeLabelOverride == "Bit-perfect" && whyNotBitPerfect.isEmpty }

    var bitPerfectExplanation: String {
        if isVerifiedBitPerfect { return "Bit-perfect is verified by the available source, processing, volume, and output data." }
        return "Bit-perfect: cannot verify"
    }

    /// Generate a signal path from stored track metadata only. This intentionally
    /// shows unknown processing/output instead of decorating absent facts.
    static func from(track: Track, isBitPerfect: Bool = false) -> AudioSignalPath {
        fromPlaybackState(
            track: track,
            sourceFormat: track.audioType?.uppercased() ?? audioFormatFromURL(track.url ?? ""),
            selectedStreamURL: nil,
            outputFormat: "",
            localVolume: 1.0,
            lmsQuality: nil,
            orpheusState: nil
        )
    }

    /// Build the real-time signal path from actual app/LMS/track/Orpheus state.
    /// The model is conservative by design: it can explain "direct-looking" paths,
    /// but it does not upgrade them to bit-perfect/lossless unless every required
    /// processing and output fact is known.
    static func fromPlaybackState(
        track: Track,
        sourceFormat: String,
        selectedStreamURL: URL?,
        outputFormat: String,
        outputDeviceName: String = "",
        localVolume: Float,
        lmsQuality: LMSAudioQuality? = nil,
        orpheusState: OrpheusSignalPathState? = nil,
        decodedFormat: String = "",
        airPlayFallback: Bool = false
    ) -> AudioSignalPath {
        var steps: [AudioPathStep] = []
        var usedFields: [String] = []
        var missingFields = Set<String>()
        var notes: [String] = []
        var whyNotBitPerfect: [String] = []

        let codec = firstNonEmpty(lmsQuality?.type, track.audioType, sourceFormat, audioFormatFromURL(track.url ?? ""))
        let normalizedCodec = codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let codecKnown = !normalizedCodec.isEmpty && normalizedCodec != "unknown"
        if codecKnown { usedFields.append("type/sourceFormat") } else { missingFields.insert("type") }

        let sampleRate = positive(lmsQuality?.sampleRate) ?? positive(track.sampleRate)
        let sampleSize = positive(lmsQuality?.sampleSize) ?? positive(track.sampleSize)
        let bitrate = firstNonEmpty(lmsQuality?.bitrate, track.bitrate)
        let reportedLossless = lmsQuality?.lossless ?? track.lossless
        let replayGain = lmsQuality?.replayGain ?? track.replayGain
        let albumReplayGain = lmsQuality?.albumReplayGain ?? track.albumReplayGain
        if sampleRate != nil { usedFields.append("samplerate") } else { missingFields.insert("samplerate") }
        if sampleSize != nil { usedFields.append("samplesize") } else { missingFields.insert("samplesize") }
        if !bitrate.isEmpty { usedFields.append("bitrate") } else { missingFields.insert("bitrate") }
        if reportedLossless != nil { usedFields.append("lossless") } else { missingFields.insert("lossless") }
        if replayGain != nil || albumReplayGain != nil { usedFields.append("replay_gain/album_replay_gain") } else { missingFields.insert("replay_gain") }

        let sourceIsLossless: Bool? = {
            if let reportedLossless { return reportedLossless }
            guard codecKnown else { return nil }
            if AudioFormats.isLosslessCodec(normalizedCodec) { return true }
            if AudioFormats.isLossyCodec(normalizedCodec) { return false }
            return nil
        }()

        let sourceTechnical = sourceTechnicalValue(codec: codecKnown ? normalizedCodec.uppercased() : nil,
                                                   sampleRate: sampleRate,
                                                   sampleSize: sampleSize,
                                                   bitrate: bitrate,
                                                   lossless: sourceIsLossless)
        steps.append(AudioPathStep(
            id: "source",
            icon: "opticaldisc",
            title: "Source",
            subtitle: sourceTechnical.isEmpty ? "Source format not reported by LMS" : sourceTechnical,
            status: sourceIsLossless == true ? .lossless : (sourceIsLossless == false ? .converted : .unknown),
            statusLabel: sourceIsLossless == true ? "Lossless source" : (sourceIsLossless == false ? "Lossy source" : "Unknown"),
            confidence: (lmsQuality != nil || track.audioType != nil || track.sampleRate != nil) ? .reported : .unknown,
            technicalValue: sourceTechnical.isEmpty ? nil : sourceTechnical,
            explanation: sourceIsLossless == true
                ? "LMS/track metadata reports a lossless source container. This does not prove the whole playback path is lossless."
                : (sourceIsLossless == false
                   ? "The source codec or LMS lossless flag indicates a lossy source, so bit-perfect/lossless output is not claimed."
                   : "Hyperion did not receive enough LMS/track metadata to classify the source as lossless or lossy."),
            sourceOfTruth: lmsQuality != nil ? "LMS songinfo/status + Track metadata" : "Track metadata / URL extension fallback",
            usedFields: ["type", "samplerate", "samplesize", "bitrate", "lossless"].filter { !missingFields.contains($0) },
            missingFields: ["type", "samplerate", "samplesize", "bitrate", "lossless"].filter { missingFields.contains($0) }
        ))
        if sourceIsLossless == false { whyNotBitPerfect.append("Source is lossy or reported as not lossless.") }
        if sourceIsLossless == nil { whyNotBitPerfect.append("Source lossless/lossy state is not fully reported by LMS.") }

        let streamDescription = selectedStreamURL.map { streamSummary($0) } ?? "Selected stream URL not recorded"
        let streamExt = selectedStreamURL?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let sourceExt = codecKnown ? normalizedCodec : ""
        let sourceExtNorm = AudioFormats.canonicalExtension(forLMSCodec: sourceExt)
        let streamExtNorm = AudioFormats.canonicalExtension(forLMSCodec: streamExt)
        let appearsTranscoded = codecKnown && !streamExtNorm.isEmpty && sourceExtNorm != streamExtNorm && streamExtNorm != "download"
        let decodedFormatKnown = !decodedFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !decodedFormat.hasPrefix("unknown")
        steps.append(AudioPathStep(
            id: "decode",
            icon: "waveform",
            title: "Decode",
            subtitle: decodedFormatKnown ? decodedFormat : "AVPlayer",
            status: .unknown,
            statusLabel: decodedFormatKnown ? "Detected" : "Not reported",
            confidence: decodedFormatKnown ? .verified : .reported,
            technicalValue: decodedFormatKnown ? decodedFormat : (selectedStreamURL == nil ? nil : streamDescription),
            explanation: "Hyperion decodes the LMS stream via AVPlayer/AVURLAsset. When Orpheus is active, the exact decoded format is read from AVAssetTrack.",
            sourceOfTruth: decodedFormatKnown
                ? "AVAssetTrack.formatDescriptions (Orpheus engine)"
                : "Hyperion playback — AVPlayer direct stream",
            usedFields: [decodedFormatKnown ? "decodedFormat" : nil,
                         selectedStreamURL == nil ? nil : "selectedStreamURL"].compactMap { $0 },
            missingFields: decodedFormatKnown ? [] : (selectedStreamURL == nil ? ["selectedStreamURL"] : [])
        ))

        // LMS processing — use tags=A stream fields when available, fall back to URL heuristic.
        let streamSR  = lmsQuality?.streamSampleRate.flatMap { $0 > 0 ? $0 : nil }
        let streamBD  = lmsQuality?.streamBitDepth.flatMap  { $0 > 0 ? $0 : nil }
        let streamBR  = lmsQuality?.streamBitRate.flatMap   { $0.isEmpty ? nil : $0 }
        var streamFmtParts: [String] = []
        if let sr = streamSR { streamFmtParts.append(formatSampleRate(sr)) }
        if let bd = streamBD { streamFmtParts.append("\(bd)-bit") }
        if let br = streamBR { streamFmtParts.append(br) }
        let streamFmtStr = streamFmtParts.isEmpty ? nil : streamFmtParts.joined(separator: " / ")

        let isDirect: Bool? = {
            if let sr = streamSR, let srcRate = sampleRate, srcRate > 0 {
                return sr == srcRate && (streamBD == nil || streamBD == sampleSize)
            }
            // No LMS player-session data — infer direct when codec matches stream and source is lossless
            if !appearsTranscoded, sourceIsLossless == true { return true }
            return nil
        }()

        let lmsSubtitle: String
        let lmsStatus: QualityStatus
        let lmsTechValue: String?
        let lmsSourceOfTruth: String
        let lmsMissingFields: [String]

        if isDirect == true {
            lmsSubtitle     = "Direct — no transcode"
            lmsStatus       = .lossless
            lmsTechValue    = streamFmtStr
            lmsSourceOfTruth = "LMS status audio_ fields (tags=A)"
            lmsMissingFields = []
        } else if let sfStr = streamFmtStr {
            lmsSubtitle     = "Transcoded to \(sfStr)"
            lmsStatus       = .converted
            lmsTechValue    = sfStr
            lmsSourceOfTruth = "LMS status audio_ fields (tags=A)"
            lmsMissingFields = []
        } else if appearsTranscoded {
            lmsSubtitle     = "Stream extension differs from source codec"
            lmsStatus       = .converted
            lmsTechValue    = streamDescription.isEmpty ? nil : streamDescription
            lmsSourceOfTruth = "LMS stream URL + source metadata heuristic"
            lmsMissingFields = ["audio_samplerate", "audio_bitdepth"]
        } else {
            lmsSubtitle     = "Transcode format not reported"
            lmsStatus       = .unknown
            lmsTechValue    = streamDescription.isEmpty ? nil : streamDescription
            lmsSourceOfTruth = "LMS stream URL + source metadata"
            lmsMissingFields = ["audio_samplerate", "audio_bitdepth"]
        }

        steps.append(AudioPathStep(
            id: "lms-processing",
            icon: "network",
            title: "LMS processing",
            subtitle: lmsSubtitle,
            status: lmsStatus,
            statusLabel: isDirect == true ? "Direct" : (streamFmtStr != nil ? "Transcoded" : (appearsTranscoded ? "Transcoded?" : "Unknown")),
            confidence: isDirect != nil ? .reported : (appearsTranscoded ? .unverified : .unknown),
            technicalValue: lmsTechValue,
            explanation: isDirect == true
                ? "LMS is streaming the source file without transcoding — sample rate and bit depth match the library file."
                : (streamFmtStr != nil
                   ? "LMS is delivering a transcoded stream to Hyperion. Source and stream formats differ."
                   : "LMS transcode state was not reported. tags=A requires an active LMS player streaming to a registered output."),
            sourceOfTruth: lmsSourceOfTruth,
            usedFields: streamFmtStr != nil ? ["audio_samplerate", "audio_bitdepth"] : (selectedStreamURL == nil ? [] : ["selectedStreamURL", "type"]),
            missingFields: lmsMissingFields
        ))
        if isDirect != true {
            whyNotBitPerfect.append(streamFmtStr != nil
                ? "LMS is transcoding the source stream."
                : "LMS transcode format is not reported (tags=A unavailable or LMS player not active).")
            missingFields.insert("final_output_format")
        }

        let replayText: String
        let replayTech: String?
        if let rg = replayGain {
            replayTech = String(format: "Track %.2f dB", rg)
            replayText = "ReplayGain value reported; application to Hyperion stream is not verified"
        } else if let albumRG = albumReplayGain {
            replayTech = String(format: "Album %.2f dB", albumRG)
            replayText = "Album ReplayGain value reported; application to Hyperion stream is not verified"
        } else {
            replayTech = nil
            replayText = "ReplayGain / volume normalization not reported by LMS"
        }
        steps.append(AudioPathStep(
            id: "replaygain",
            icon: "dial.low",
            title: "ReplayGain / volume normalization",
            subtitle: replayText,
            status: (replayGain != nil || albumReplayGain != nil) ? .unknown : .unknown,
            statusLabel: (replayGain != nil || albumReplayGain != nil) ? "Reported tag" : "Unknown",
            confidence: (replayGain != nil || albumReplayGain != nil) ? .reported : .unknown,
            technicalValue: replayTech,
            explanation: "LMS can report ReplayGain metadata. Hyperion does not treat that as proof that LMS applied volume normalization unless an applied status field is present.",
            sourceOfTruth: "LMS songinfo/status replay_gain fields",
            usedFields: (replayGain != nil || albumReplayGain != nil) ? ["replay_gain", "album_replay_gain"] : [],
            missingFields: (replayGain != nil || albumReplayGain != nil) ? [] : ["replay_gain_applied"]
        ))
        whyNotBitPerfect.append("ReplayGain/volume-normalization application is not verified by LMS status.")

        let orpheusSteps = buildOrpheusSteps(orpheusState)
        steps.append(contentsOf: orpheusSteps.steps)
        notes.append(contentsOf: orpheusSteps.notes)
        if orpheusSteps.processingAffectsPath {
            whyNotBitPerfect.append("Orpheus DSP is active in the verified playback path.")
        }
        let isOrpheusActive   = orpheusSteps.isOrpheusActive
        let isPureModeEnabled = orpheusSteps.isPureModeEnabled

        if airPlayFallback {
            steps.append(AudioPathStep(
                id: "airplay-bypass",
                icon: "airplayvideo",
                title: "AirPlay output",
                subtitle: "Orpheus DSP bypassed — AirPlay cannot route through AVAudioEngine",
                status: .converted,
                statusLabel: "DSP bypassed",
                confidence: .verified,
                technicalValue: "Orpheus → AVPlayer fallback",
                explanation: "When AirPlay is active, Hyperion falls back from the Orpheus DSP chain to direct AVPlayer playback. EQ, crossfeed, headroom, and leveling are inactive on this route.",
                sourceOfTruth: "AVAudioSession.routeChangeNotification / Hyperion fallback logic",
                usedFields: ["AVAudioSession.currentRoute"],
                missingFields: []
            ))
            whyNotBitPerfect.append("Orpheus DSP is configured but bypassed due to AirPlay output.")
        }

        let volumePercent = Int((max(0, min(1, localVolume)) * 100).rounded())
        let hasLocalAttenuation = volumePercent < 100
        steps.append(AudioPathStep(
            id: "volume",
            icon: "speaker.wave.2",
            title: "Digital volume",
            subtitle: hasLocalAttenuation ? "\(volumePercent)% — AVPlayer digital attenuation" : "100% — no local attenuation reported by Hyperion",
            status: hasLocalAttenuation ? .enhanced : .lossless,
            statusLabel: hasLocalAttenuation ? "Attenuated" : "Full scale",
            confidence: .verified,
            technicalValue: "\(volumePercent)%",
            explanation: hasLocalAttenuation
                ? "Hyperion sets AVPlayer volume below full scale, so digital volume attenuation is happening before output."
                : "Hyperion's local AVPlayer volume is at full scale. This does not verify LMS/player hardware volume or OS output processing.",
            sourceOfTruth: "Hyperion PlayerViewModel.volume / AVPlayer.volume",
            usedFields: ["localVolume"],
            missingFields: ["lms_player_volume", "hardware_volume"]
        ))
        if hasLocalAttenuation { whyNotBitPerfect.append("Hyperion local digital volume is below 100%.") }
        missingFields.insert("hardware_volume")

        if let lmsQuality {
            let statusMatchText: String
            switch lmsQuality.statusMatchedCurrentTrack {
            case true:  statusMatchText = "LMS status matched current Hyperion track"
            case false: statusMatchText = "LMS status did not match current Hyperion track"
            case nil:   statusMatchText = "LMS status match not reported"
            }
            var playerParts: [String] = []
            if let playerName = lmsQuality.playerName, !playerName.isEmpty { playerParts.append(playerName) }
            if let playerMode = lmsQuality.playerMode, !playerMode.isEmpty { playerParts.append("mode: \(playerMode)") }
            if let lmsVolume = lmsQuality.lmsVolume { playerParts.append("LMS volume: \(lmsVolume)") }
            let technical = playerParts.isEmpty ? nil : playerParts.joined(separator: " · ")
            steps.append(AudioPathStep(
                id: "lms-player-status",
                icon: "hifispeaker.2",
                title: "LMS player/status",
                subtitle: statusMatchText,
                status: lmsQuality.statusMatchedCurrentTrack == true ? .unknown : .unknown,
                statusLabel: lmsQuality.statusMatchedCurrentTrack == true ? "Reported" : "Diagnostic",
                confidence: lmsQuality.statusMatchedCurrentTrack == true ? .reported : .unverified,
                technicalValue: technical,
                explanation: "This is LMS player status for diagnostics. Hyperion's audible playback path is the selected AVPlayer stream, so an LMS player status row is not treated as proof of final output processing.",
                sourceOfTruth: "LMS status response",
                usedFields: ["player_name", "mode", "mixer volume"],
                missingFields: technical == nil ? ["player_name", "mode", "mixer volume"] : []
            ))
            if lmsQuality.statusMatchedCurrentTrack == false {
                notes.append("LMS status response did not match the current Hyperion track; status-only fields were kept diagnostic.")
            }
        }

        let outputKnown = !outputFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let deviceLine: String = {
            let dev = outputDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fmt = outputFormat.trimmingCharacters(in: .whitespacesAndNewlines)
            if dev.isEmpty && fmt.isEmpty { return "Not reported" }
            if dev.isEmpty { return fmt }
            if fmt.isEmpty { return dev }
            return "\(dev) · \(fmt)"
        }()
        steps.append(AudioPathStep(
            id: "output",
            icon: "headphones",
            title: "Output",
            subtitle: outputKnown ? deviceLine : "Output device not reported",
            status: outputKnown ? .unknown : .unknown,
            statusLabel: outputKnown ? "Route known" : "Unknown",
            confidence: outputKnown ? .reported : .unknown,
            technicalValue: outputKnown ? deviceLine : nil,
            explanation: "iOS audio route snapshot. Does not expose final bit depth, DAC internals, or OS mixing.",
            sourceOfTruth: outputKnown ? "AVAudioSession.currentRoute + portName" : "Not reported",
            usedFields: outputKnown ? ["AVAudioSession.currentRoute", "portName", "sampleRate"] : [],
            missingFields: ["final_output_bit_depth", "device_internal_processing"]
        ))
        whyNotBitPerfect.append("Final output bit depth and device/OS processing are not reported.")
        missingFields.insert("final_output_bit_depth")
        missingFields.insert("device_internal_processing")

        let badge = badge(forSourceLossless: sourceIsLossless,
                          appearsTranscoded: appearsTranscoded,
                          isDirect: isDirect,
                          hasLocalAttenuation: hasLocalAttenuation,
                          orpheusProcessingAffectsPath: orpheusSteps.processingAffectsPath,
                          isOrpheusActive: isOrpheusActive,
                          isPureModeEnabled: isPureModeEnabled,
                          airPlayFallback: airPlayFallback)
        steps.append(AudioPathStep(
            id: "verification",
            icon: badge.label == "Bit-perfect" ? "checkmark.circle.fill" : "questionmark.circle",
            title: "Verification",
            subtitle: badge.label == "Bit-perfect" ? "Full path verified" : "Bit-perfect: cannot verify",
            status: badge.status,
            statusLabel: badge.label == "Bit-perfect" ? "Verified" : "Not claimed",
            confidence: badge.label == "Bit-perfect" ? .verified : .unknown,
            technicalValue: badge.label,
            explanation: whyNotBitPerfect.isEmpty
                ? "Every required source, processing, volume, transcode, and output field supports a direct path."
                : whyNotBitPerfect.joined(separator: " "),
            sourceOfTruth: "Derived from all available signal-path fields",
            usedFields: usedFields,
            missingFields: Array(missingFields).sorted()
        ))

        var diagnostics = SignalPathDiagnostics(
            rawTrackFields: lmsQuality?.rawTrackFields ?? rawTrackFields(from: track),
            rawStatusFields: lmsQuality?.rawStatusFields ?? [:],
            usedFields: Array(Set((lmsQuality?.fieldsUsed ?? []) + usedFields)).sorted(),
            missingFields: Array(Set((lmsQuality?.missingFields ?? []) + Array(missingFields))).sorted(),
            notes: notes
        )
        if diagnostics.notes.isEmpty {
            diagnostics.notes.append("Signal path is intentionally conservative: unknown/unreported fields stay unknown.")
        }

        return AudioSignalPath(steps: steps,
                               badgeStatus: badge.status,
                               badgeLabelOverride: badge.label,
                               diagnostics: diagnostics,
                               whyNotBitPerfect: Array(NSOrderedSet(array: whyNotBitPerfect).compactMap { $0 as? String }))
    }

    private static func buildOrpheusSteps(_ state: OrpheusSignalPathState?)
        -> (steps: [AudioPathStep], processingAffectsPath: Bool, isOrpheusActive: Bool, isPureModeEnabled: Bool, notes: [String])
    {
        guard let state else {
            return ([AudioPathStep(
                id: "orpheus",
                icon: "slider.horizontal.3",
                title: "Orpheus processing",
                subtitle: "Orpheus state not available",
                status: .unknown,
                statusLabel: "Unknown",
                confidence: .unknown,
                explanation: "Hyperion could not read Orpheus DSP/EQ settings for this signal-path snapshot.",
                sourceOfTruth: "Not reported",
                missingFields: ["orpheus_state"]
            )], false, false, false, [])
        }

        let presetSuffix    = state.activePresetName.map { " — preset '\($0)'" } ?? ""
        let isOrpheusActive = state.isPlaybackRoutedThroughOrpheus
        var notes: [String] = []

        if !state.isPlaybackRoutedThroughOrpheus, state.hasAnyConfiguredProcessing {
            notes.append("Orpheus has configured processing, but current playback uses AVPlayer compatibility mode and is not verified to pass through the Orpheus DSP chain.")
        }

        // Pure Mode + Orpheus active: all DSP intentionally bypassed on the graph.
        if state.isPlaybackRoutedThroughOrpheus && state.isPureModeEnabled {
            let step = AudioPathStep(
                id: "orpheus-pure",
                icon: "waveform.path",
                title: "Orpheus · Pure Mode",
                subtitle: "Orpheus playback engine active — all intentional DSP processing bypassed\(presetSuffix)",
                status: .lossless,
                statusLabel: "Pure Mode",
                confidence: .verified,
                explanation: "Pure Mode disables EQ, crossfeed, leveling, balance, headroom, and all other intentional Hyperion processing. Saved settings are preserved unchanged and will restore when Pure Mode is turned off. Final iOS/device output may still apply its own processing depending on the current audio route.",
                sourceOfTruth: "OrpheusDSPEngine.isPureModeEnabled + isPlaybackRoutedThroughOrpheus",
                usedFields: ["isPureModeEnabled", "isPlaybackRoutedThroughOrpheus"]
            )
            return ([step], false, true, true, notes)
        }

        // Pure Mode configured but Orpheus not active (compatibility/AVPlayer fallback).
        if !state.isPlaybackRoutedThroughOrpheus && state.isPureModeEnabled {
            let step = AudioPathStep(
                id: "orpheus-pure-unavailable",
                icon: "waveform.path",
                title: "Orpheus · Pure Mode",
                subtitle: "Pure Mode configured, but Orpheus playback engine is not active",
                status: .unknown,
                statusLabel: "Unavailable",
                confidence: .configured,
                explanation: "Playback is using AVPlayer compatibility mode. Orpheus processing (including Pure Mode bypass) is not active on this stream.",
                sourceOfTruth: "OrpheusDSPEngine.isPureModeEnabled + isPlaybackRoutedThroughOrpheus",
                usedFields: ["isPureModeEnabled", "isPlaybackRoutedThroughOrpheus"]
            )
            return ([step], false, false, true, notes)
        }

        // No intentional DSP configured.
        if !state.hasAnyConfiguredProcessing {
            return ([AudioPathStep(
                id: "orpheus",
                icon: "slider.horizontal.3",
                title: "Orpheus processing",
                subtitle: "No active Orpheus EQ/DSP settings reported\(presetSuffix)",
                status: .lossless,
                statusLabel: "Bypassed",
                confidence: .configured,
                explanation: "Orpheus settings do not report active EQ, crossfeed, headroom, leveling, balance, or SRC preferences. This only covers Hyperion's Orpheus settings, not LMS or OS processing.",
                sourceOfTruth: "OrpheusDSPEngine settings",
                usedFields: ["orpheusSettings"]
            )], false, isOrpheusActive, false, notes)
        }

        // Normal DSP active or configured.
        let configuredItems = state.isPlaybackRoutedThroughOrpheus ? state.activeItems : state.configuredOnlyItems
        let subtitle = state.isPlaybackRoutedThroughOrpheus
            ? "\(configuredItems.count) active item(s) in verified Orpheus path\(presetSuffix)"
            : "\(configuredItems.count) configured item(s), not verified in playback path\(presetSuffix)"
        var steps = [AudioPathStep(
            id: "orpheus-summary",
            icon: "slider.horizontal.3",
            title: "Orpheus processing",
            subtitle: subtitle,
            status: state.isPlaybackRoutedThroughOrpheus ? .enhanced : .unknown,
            statusLabel: state.isPlaybackRoutedThroughOrpheus ? "Active" : "Configured only",
            confidence: state.isPlaybackRoutedThroughOrpheus ? .verified : .configured,
            explanation: state.isPlaybackRoutedThroughOrpheus
                ? "These Orpheus DSP/EQ stages are active in the playback path."
                : "These Orpheus settings are enabled/configured, but Hyperion's current playback uses AVPlayer direct streaming and is not verified to pass through this AVAudioEngine chain.",
            sourceOfTruth: "OrpheusDSPEngine settings + AudioPlayerManager routing flag",
            usedFields: ["orpheusSettings", "isPlaybackRoutedThroughOrpheus"]
        )]

        for item in configuredItems {
            steps.append(AudioPathStep(
                id: "orpheus-\(item.id)",
                icon: iconForOrpheusItem(item.title),
                title: item.title,
                subtitle: item.technicalValue,
                status: state.isPlaybackRoutedThroughOrpheus ? .enhanced : .unknown,
                statusLabel: state.isPlaybackRoutedThroughOrpheus ? "Active" : "Configured",
                confidence: state.isPlaybackRoutedThroughOrpheus ? .verified : .configured,
                technicalValue: item.technicalValue,
                explanation: item.explanation,
                sourceOfTruth: "OrpheusDSPEngine settings"
            ))
        }
        return (steps, state.isPlaybackRoutedThroughOrpheus && !configuredItems.isEmpty, isOrpheusActive, false, notes)
    }

    private static func badge(
        forSourceLossless sourceIsLossless: Bool?,
        appearsTranscoded: Bool,
        isDirect: Bool?,
        hasLocalAttenuation: Bool,
        orpheusProcessingAffectsPath: Bool,
        isOrpheusActive: Bool,
        isPureModeEnabled: Bool,
        airPlayFallback: Bool = false
    ) -> (label: String, status: QualityStatus) {
        if sourceIsLossless == false { return ("Lossy source", .converted) }
        if appearsTranscoded { return ("Transcoded?", .converted) }
        if airPlayFallback { return ("AirPlay · DSP bypass", .converted) }
        if isOrpheusActive {
            if isPureModeEnabled { return ("Orpheus · Pure", .unknown) }
            if orpheusProcessingAffectsPath { return ("Orpheus · DSP", .enhanced) }
            return ("Orpheus", .unknown)
        }
        if hasLocalAttenuation || orpheusProcessingAffectsPath { return ("Processed", .enhanced) }
        if isDirect == true { return ("Direct", .lossless) }
        if sourceIsLossless == true { return ("Direct?", .lossless) }
        return ("Unknown", .unknown)
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func sourceTechnicalValue(codec: String?, sampleRate: Int?, sampleSize: Int?, bitrate: String, lossless: Bool?) -> String {
        var parts: [String] = []
        if let codec, !codec.isEmpty { parts.append(codec) }
        if let sampleRate { parts.append(formatSampleRate(sampleRate)) }
        if let sampleSize { parts.append("\(sampleSize)-bit") }
        if !bitrate.isEmpty { parts.append(bitrate) }
        if let lossless { parts.append(lossless ? "lossless source" : "lossy source") }
        return parts.joined(separator: " / ")
    }

    static func formatSampleRate(_ hz: Int) -> String {
        let khz = Double(hz) / 1000.0
        if khz.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f kHz", khz)
        }
        return String(format: "%.1f kHz", khz)
    }

    private static func streamSummary(_ url: URL) -> String {
        var path = url.path
        if path.count > 72 { path = "…" + path.suffix(72) }
        if url.query?.isEmpty == false { return "\(path)?…" }
        return path
    }

    private static func iconForOrpheusItem(_ title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("eq") { return "slider.horizontal.below.rectangle" }
        if lower.contains("headroom") { return "gauge.with.dots.needle.67percent" }
        if lower.contains("crossfeed") { return "ear" }
        if lower.contains("level") { return "waveform" }
        if lower.contains("balance") { return "speaker.wave.2" }
        if lower.contains("sample") || lower.contains("src") { return "arrow.triangle.2.circlepath" }
        return "slider.horizontal.3"
    }

    private static func rawTrackFields(from track: Track) -> [String: String] {
        var out: [String: String] = [:]
        if let audioType = track.audioType { out["type"] = audioType }
        if let sampleRate = track.sampleRate { out["samplerate"] = String(sampleRate) }
        if let sampleSize = track.sampleSize { out["samplesize"] = String(sampleSize) }
        if let bitrate = track.bitrate { out["bitrate"] = bitrate }
        if let lossless = track.lossless { out["lossless"] = String(lossless) }
        if let replayGain = track.replayGain { out["replay_gain"] = String(replayGain) }
        if let albumReplayGain = track.albumReplayGain { out["album_replay_gain"] = String(albumReplayGain) }
        if let url = track.url { out["url"] = ServerLogStore.redactedURL(url) }
        return out
    }

    private static func audioFormatFromURL(_ url: String) -> String {
        if let u = URL(string: url), !u.pathExtension.isEmpty {
            return u.pathExtension.uppercased()
        }
        let ext = (url as NSString).pathExtension
        return ext.isEmpty ? "Unknown" : ext.uppercased()
    }

    static let mockPath = AudioSignalPath(
        steps: [
            AudioPathStep(
                id: "source",
                icon: "opticaldisc",
                title: "Source",
                subtitle: "FLAC / 96 kHz / 24-bit / lossless source",
                status: .lossless,
                statusLabel: "Lossless source",
                confidence: .reported,
                technicalValue: "FLAC / 96 kHz / 24-bit",
                explanation: "LMS songinfo reports a lossless FLAC source.",
                sourceOfTruth: "LMS songinfo + Track metadata",
                usedFields: ["type", "samplerate", "samplesize", "lossless"],
                missingFields: ["bitrate"]
            ),
            AudioPathStep(
                id: "decode",
                icon: "waveform",
                title: "Decode",
                subtitle: "PCM Float32 96000 Hz 2ch",
                status: .unknown,
                statusLabel: "Detected",
                confidence: .verified,
                technicalValue: "PCM Float32 96000 Hz 2ch",
                explanation: "AVAssetTrack format detected by Orpheus engine.",
                sourceOfTruth: "AVAssetTrack.formatDescriptions (Orpheus engine)"
            ),
            AudioPathStep(
                id: "lms-processing",
                icon: "network",
                title: "LMS processing",
                subtitle: "Direct — no transcode",
                status: .lossless,
                statusLabel: "Direct",
                confidence: .reported,
                technicalValue: "96 kHz / 24-bit",
                explanation: "LMS status tags=A confirms source sample rate matches stream.",
                sourceOfTruth: "LMS status audio_ fields (tags=A)",
                usedFields: ["audio_samplerate", "audio_bitdepth"]
            ),
            AudioPathStep(
                id: "replaygain",
                icon: "dial.medium",
                title: "ReplayGain / volume normalization",
                subtitle: "ReplayGain value reported",
                status: .unknown,
                statusLabel: "Reported tag",
                confidence: .reported,
                technicalValue: "Track -1.23 dB",
                explanation: "Tag present; application not verified.",
                sourceOfTruth: "LMS songinfo replay_gain field"
            ),
            AudioPathStep(
                id: "volume",
                icon: "speaker.wave.2",
                title: "Digital volume",
                subtitle: "100% — no local attenuation",
                status: .lossless,
                statusLabel: "Full scale",
                confidence: .verified,
                technicalValue: "100%",
                sourceOfTruth: "Hyperion PlayerViewModel.volume / AVPlayer.volume"
            ),
            AudioPathStep(
                id: "output",
                icon: "headphones",
                title: "Output",
                subtitle: "AirPods Pro · 48 kHz · 2ch",
                status: .unknown,
                statusLabel: "Route known",
                confidence: .reported,
                technicalValue: "AirPods Pro · 48 kHz · 2ch",
                explanation: "iOS audio route snapshot.",
                sourceOfTruth: "AVAudioSession.currentRoute + portName",
                usedFields: ["AVAudioSession.currentRoute", "portName", "sampleRate"]
            ),
        ],
        badgeStatus: .unknown,
        badgeLabelOverride: "Direct?",
        diagnostics: SignalPathDiagnostics(notes: ["Preview data; real playback uses LMS/track/player fields."]),
        whyNotBitPerfect: ["Final output bit depth and device/OS processing are not reported."]
    )
}
