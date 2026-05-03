import Foundation

/// URL normalisation and candidate generation for LMS/Lyrion servers.
///
/// LyrPlay-style remote setup commonly uses a Tailscale/MagicDNS hostname
/// rather than a fully-qualified `http://host:9000` URL. Hyperion accepts the
/// same loose input and probes the LMS-native port/path candidates before
/// falling back to the literal URL.
enum HyperionServerURL {
    static func sanitizedBase(_ rawURL: String) -> String {
        guard let components = normalizedComponents(rawURL, assumeScheme: true) else { return "" }
        return string(from: stripKnownEndpointPath(components))
    }

    static func candidateBases(for rawURL: String, mode: ConnectionMode? = nil) -> [String] {
        let original = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return [] }

        let hadScheme = original.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        guard let normalized = normalizedComponents(original, assumeScheme: true) else { return [] }

        let stripped = stripKnownEndpointPath(normalized)
        let hostKind = connectionKind(forHost: stripped.host?.lowercased() ?? "")
        let explicitPort = stripped.port != nil
        let scheme = stripped.scheme?.lowercased() ?? "http"

        var candidates: [URLComponents] = []

        func append(_ components: URLComponents) {
            candidates.append(components)
        }

        func with(scheme newScheme: String? = nil, port newPort: Int? = nil, clearPort: Bool = false) -> URLComponents {
            var copy = stripped
            if let newScheme { copy.scheme = newScheme }
            if clearPort { copy.port = nil }
            if let newPort { copy.port = newPort }
            return copy
        }

        if !hadScheme {
            switch mode {
            case .proxy:
                // Bare public domains are most often HTTPS reverse proxies.
                append(with(scheme: "https", clearPort: true))
                append(with(scheme: "http", port: 9000))
                append(with(scheme: "http", clearPort: true))
            default:
                if hostKind == .remote {
                    append(with(scheme: "https", clearPort: true))
                    append(with(scheme: "http", port: 9000))
                    append(with(scheme: "http", clearPort: true))
                } else {
                    append(with(scheme: "http", port: 9000))
                    append(with(scheme: "http", clearPort: true))
                    append(with(scheme: "https", clearPort: true))
                }
            }
        } else {
            append(stripped)
            if !explicitPort, scheme == "http" {
                append(with(port: 9000))
            }
            if !explicitPort, scheme == "https", mode != .proxy, hostKind != .remote {
                append(with(scheme: "http", port: 9000))
            }
        }

        return unique(candidates.map(string(from:)).filter { !$0.isEmpty })
    }

    static func redactedDisplay(_ rawURL: String) -> String {
        let sanitized = sanitizedBase(rawURL)
        return sanitized.isEmpty ? "not set" : ServerLogStore.redactedURL(sanitized)
    }

    static func connectionKind(for rawURL: String) -> URLConnectionKind {
        guard let components = normalizedComponents(rawURL, assumeScheme: true),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return .remote
        }
        return connectionKind(forHost: host)
    }

    enum URLConnectionKind: Equatable {
        case local
        case tailscale
        case remote

        var displayName: String {
            switch self {
            case .local:     return "Home"
            case .tailscale: return "Tailscale"
            case .remote:    return "Remote"
            }
        }
    }

    private static func normalizedComponents(_ rawURL: String, assumeScheme: Bool) -> URLComponents? {
        var result = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }

        // Avoid re-running the regex if the caller already checked — but since
        // the private API doesn't accept a pre-computed value, we check once here.
        let hasScheme = result.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        if assumeScheme && !hasScheme {
            result = "http://" + result
        }

        // Strip trailing slashes beyond the minimum scheme length so URLComponents
        // doesn't misparse "http://host/" as having a "/" path component.
        while result.count > "https://".count && result.hasSuffix("/") {
            result.removeLast()
        }

        guard var components = URLComponents(string: result), components.host != nil else { return nil }
        components.scheme = components.scheme?.lowercased()
        return components
    }

    private static func stripKnownEndpointPath(_ components: URLComponents) -> URLComponents {
        var copy = components
        var path = copy.percentEncodedPath
        guard !path.isEmpty, path != "/" else {
            copy.percentEncodedPath = ""
            return copy
        }

        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        let lower = path.lowercased()

        let knownSuffixes = [
            "/jsonrpc.js",
            "/material",
            "/material/",
            "/index.html"
        ]
        for suffix in knownSuffixes where lower == suffix || lower.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }

        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        copy.percentEncodedPath = path == "/" ? "" : path
        return copy
    }

    private static func string(from components: URLComponents) -> String {
        guard var url = components.url?.absoluteString, !url.isEmpty else { return "" }
        while url.count > "https://".count && url.hasSuffix("/") {
            url.removeLast()
        }
        return url == "http://" || url == "https://" ? "" : url
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func connectionKind(forHost host: String) -> URLConnectionKind {
        if host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") {
            return .local
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            let a = octets[0]
            let b = octets[1]
            if a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) {
                return .local
            }
            if a == 100 && (64...127).contains(b) {
                return .tailscale
            }
            return .remote
        }

        // MagicDNS names such as server.tailnet.ts.net are private in practice.
        if host.hasSuffix(".ts.net") || host.contains(".tailnet-") {
            return .tailscale
        }
        return .remote
    }
}
