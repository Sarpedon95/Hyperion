import Foundation

/// Detects streaming service source from LMS track metadata.
enum StreamingServiceDetector {
    /// Analyzes a track's URL and metadata to determine streaming service source.
    /// Returns the detected service, or .local if the track is from local library.
    static func detectService(from track: Track) -> StreamSourceType {
        // If explicitly set, use it
        if let service = track.streamingService, service != .local {
            return service
        }

        // Detect from URL patterns
        if let url = track.url {
            return detectFromURL(url)
        }

        // Default to local library
        return .local
    }

    /// Detects streaming service from URL string.
    /// Checks for common patterns in LMS streaming service URLs.
    private static func detectFromURL(_ urlString: String) -> StreamSourceType {
        let lowercased = urlString.lowercased()

        // Qobuz URL patterns
        if lowercased.contains("qobuz") ||
           lowercased.contains("qbz") ||
           lowercased.hasPrefix("http") && lowercased.contains("streaming.qobuz") {
            return .qobuz
        }

        // Deezer URL patterns
        if lowercased.contains("deezer") ||
           lowercased.contains("dzr") {
            return .deezer
        }

        // Squid (or other local playback service) patterns
        if lowercased.contains("squid") ||
           lowercased.contains("squeezebox") {
            return .squid
        }

        return .local
    }

    /// Detects service from LMS extid field if present.
    /// LMS may provide extid like "qobuz://12345" format.
    static func detectFromExtID(_ extid: String?) -> StreamSourceType {
        guard let extid = extid else { return .local }
        let lowercased = extid.lowercased()

        if lowercased.hasPrefix("qobuz://") {
            return .qobuz
        }
        if lowercased.hasPrefix("deezer://") || lowercased.hasPrefix("dzr://") {
            return .deezer
        }

        return detectFromURL(extid)
    }
}

// MARK: - Track Extension

extension Track {
    /// The detected streaming service source for this track.
    var detectedService: StreamSourceType {
        StreamingServiceDetector.detectService(from: self)
    }

    /// True if this track is from a streaming service (not local library).
    var isStreamingSource: Bool {
        let service = detectedService
        return service != .local
    }
}
