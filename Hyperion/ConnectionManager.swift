import Foundation
import Combine
import Network

struct ConnectionProbeResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: String
    let endpoint: String
    let startedAt: Date
    let duration: TimeInterval
    let statusCode: Int?
    let serverVersion: String?
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        url: String,
        endpoint: String,
        startedAt: Date,
        duration: TimeInterval,
        statusCode: Int?,
        serverVersion: String?,
        errorMessage: String?
    ) {
        self.id = id
        self.url = url
        self.endpoint = endpoint
        self.startedAt = startedAt
        self.duration = duration
        self.statusCode = statusCode
        self.serverVersion = serverVersion
        self.errorMessage = errorMessage
    }

    var isSuccess: Bool { errorMessage == nil && statusCode.map { (200..<300).contains($0) } == true }

    var durationText: String { String(format: "%.2fs", duration) }

    var summary: String {
        let redacted = ServerLogStore.redactedURL(url)
        if isSuccess {
            let version = serverVersion.map { " · LMS \($0)" } ?? ""
            return "Connected to \(redacted) in \(durationText)\(version)"
        }
        let status = statusCode.map { "HTTP \($0) · " } ?? ""
        return "Failed \(redacted): \(status)\(errorMessage ?? "Unknown error")"
    }
}

@MainActor
final class ConnectionManager: ObservableObject {

    static let shared = ConnectionManager()

    private enum Keys {
        static let localURL       = "localURL"
        static let tailscaleURL   = "tailscaleURL"
        static let proxyURL       = "proxyURL"
        static let connectionMode = "connectionMode"
        static let legacyServerURL = "serverURL"
    }

    @Published var connectionMode: ConnectionMode = .auto
    @Published var isConnected: Bool = false
    @Published var currentURL: String = ""
    @Published private(set) var lastProbeResult: ConnectionProbeResult?
    @Published private(set) var lastConnectionMessage: String = "Not checked yet"

    var localURL: String     = ""
    var tailscaleURL: String = ""
    var proxyURL: String     = ""

    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.hyperion.ConnectionMonitor")
    private var isMonitoring = false

    /// Debounces rapid path-change events so WiFi→cellular handoffs don't
    /// spawn many concurrent resolves.
    private var reconnectTask: Task<Void, Never>?

    /// Deduplicates concurrent resolveConnection() callers — all await the
    /// same in-flight task rather than racing.
    ///
    /// The wrapper is a reference type so we can safely check whether the
    /// completed task is still the owner of `inFlightResolve`. `Task` itself
    /// is not a class, so it cannot be compared with `===`.
    ///
    /// THREAD SAFETY: accessed only from @MainActor context, so no locking.
    private final class ResolveTaskOwner {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }
    }

    private var inFlightResolve: ResolveTaskOwner?

    private init() {
        loadSettings()
        currentURL = resolvedURLForCurrentMode()
        LyrionAPI.shared.updateBaseURL(currentURL, persist: false)
        ServerLogStore.shared.info("Connection manager started. Mode: \(connectionMode.displayName), active URL: \(displayURL(currentURL))")
        startMonitoring()
    }

    // MARK: - Persistence

    func loadSettings() {
        let defaults = UserDefaults.standard
        let legacyURL = Self.sanitizedURL(defaults.string(forKey: Keys.legacyServerURL) ?? "")

        if let raw   = defaults.string(forKey: Keys.connectionMode),
           let saved = ConnectionMode(rawValue: raw) {
            connectionMode = saved
        }

        let storedLocal     = defaults.string(forKey: Keys.localURL)
        let storedTailscale = defaults.string(forKey: Keys.tailscaleURL)
        let storedProxy     = defaults.string(forKey: Keys.proxyURL)

        localURL     = Self.sanitizedURL(storedLocal     ?? "")
        tailscaleURL = Self.sanitizedURL(storedTailscale ?? "")
        proxyURL     = Self.sanitizedURL(storedProxy     ?? "")

        // Migration guard: older Hyperion builds had one `serverURL` setting.
        // The first remote pass put that legacy value only in Home, which meant
        // users whose single URL was a public IP / HTTPS proxy could pick
        // “Remote Proxy” and get an empty Remote field.  Classify the legacy URL
        // and seed the appropriate modern slot without overwriting explicit
        // settings the user has already entered.
        migrateLegacyServerURLIfNeeded(
            legacyURL: legacyURL,
            hadStoredLocal: !localURL.isEmpty,
            hadStoredTailscale: !tailscaleURL.isEmpty,
            hadStoredProxy: !proxyURL.isEmpty
        )
    }

    private func migrateLegacyServerURLIfNeeded(
        legacyURL: String,
        hadStoredLocal: Bool,
        hadStoredTailscale: Bool,
        hadStoredProxy: Bool
    ) {
        guard !legacyURL.isEmpty else { return }

        let legacyKind = Self.connectionKind(for: legacyURL)

        if !hadStoredLocal && !hadStoredTailscale && !hadStoredProxy {
            switch legacyKind {
            case .tailscale:
                tailscaleURL = legacyURL
                UserDefaults.standard.set(tailscaleURL, forKey: Keys.tailscaleURL)
            case .remote:
                proxyURL = legacyURL
                UserDefaults.standard.set(proxyURL, forKey: Keys.proxyURL)
            case .local:
                localURL = legacyURL
                UserDefaults.standard.set(localURL, forKey: Keys.localURL)
            }
            ServerLogStore.shared.info("Migrated old server URL into \(legacyKind.displayName): \(displayURL(legacyURL))")
            return
        }

        // Recovery for users who opened/saved the previous cleanup build: a
        // public/HTTPS legacy URL may already be sitting in Home while Remote is
        // empty. Keep Home intact, but also populate the Remote slot so Remote
        // Proxy mode works immediately.
        if !hadStoredProxy,
           proxyURL.isEmpty,
           legacyKind == .remote {
            proxyURL = legacyURL
            UserDefaults.standard.set(proxyURL, forKey: Keys.proxyURL)
            ServerLogStore.shared.info("Recovered old remote server URL into Remote: \(displayURL(legacyURL))")
        } else if !hadStoredProxy,
                  proxyURL.isEmpty,
                  connectionMode == .proxy,
                  Self.connectionKind(for: localURL) == .remote {
            proxyURL = localURL
            UserDefaults.standard.set(proxyURL, forKey: Keys.proxyURL)
            ServerLogStore.shared.info("Recovered public Home URL into Remote for Remote Proxy mode: \(displayURL(localURL))")
        }

        if !hadStoredTailscale,
           tailscaleURL.isEmpty,
           legacyKind == .tailscale {
            tailscaleURL = legacyURL
            UserDefaults.standard.set(tailscaleURL, forKey: Keys.tailscaleURL)
            ServerLogStore.shared.info("Recovered old Tailscale server URL into Tailscale: \(displayURL(legacyURL))")
        }
    }

    func saveSettings() {
        localURL     = Self.sanitizedURL(localURL)
        tailscaleURL = Self.sanitizedURL(tailscaleURL)
        proxyURL     = Self.sanitizedURL(proxyURL)

        UserDefaults.standard.set(localURL,                forKey: Keys.localURL)
        UserDefaults.standard.set(tailscaleURL,            forKey: Keys.tailscaleURL)
        UserDefaults.standard.set(proxyURL,                forKey: Keys.proxyURL)
        UserDefaults.standard.set(connectionMode.rawValue, forKey: Keys.connectionMode)

        ServerLogStore.shared.info(
            "Saved connection settings. Mode: \(connectionMode.displayName), local: \(displayURL(localURL)), tailscale: \(displayURL(tailscaleURL)), remote: \(displayURL(proxyURL))"
        )
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }

        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                ServerLogStore.shared.info("Network changed: \(Self.pathSummary(path))")
                self?.scheduleReconnect()
            }
        }
        monitor.start(queue: monitorQueue)
        isMonitoring = true
    }

    /// Call if the app is going to the background for an extended period and
    /// wants to stop receiving path-change callbacks.
    ///
    /// NWPathMonitor instances cannot be restarted after `cancel()`, so we
    /// discard the old monitor and create a fresh one in `startMonitoring()`.
    func stopMonitoring() {
        guard isMonitoring else { return }
        monitor?.cancel()
        monitor = nil
        isMonitoring = false
        ServerLogStore.shared.debug("Stopped network path monitor")
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await resolveConnection()
        }
    }

    // MARK: - Resolution

    func resolveConnection() async {
        if let existing = inFlightResolve {
            await existing.task.value
            return
        }

        let task = Task<Void, Never> { [weak self] in
            await self?.performResolve()
        }
        let owner = ResolveTaskOwner(task: task)
        inFlightResolve = owner
        await task.value

        // Clear the slot only if this task is still the owner. forceReconnect()
        // may have nilled/replaced inFlightResolve while this task was running.
        if inFlightResolve === owner {
            inFlightResolve = nil
        }
    }

    private func performResolve() async {
        let modeSnapshot      = connectionMode
        let localSnapshot     = Self.sanitizedURL(localURL)
        let tailscaleSnapshot = Self.sanitizedURL(tailscaleURL)
        let proxySnapshot     = Self.sanitizedURL(proxyURL)

        ServerLogStore.shared.info("Resolving server. Mode: \(modeSnapshot.displayName)")

        let result: ConnectionProbeResult?
        var selectedURL: String

        switch modeSnapshot {
        case .local:
            selectedURL = localSnapshot
            result = await probeConfiguredURL(selectedURL, missingMessage: "Home LAN URL is empty", mode: modeSnapshot)
        case .tailscale:
            selectedURL = tailscaleSnapshot
            result = await probeConfiguredURL(selectedURL, missingMessage: "Tailscale URL is empty", mode: modeSnapshot)
        case .proxy:
            selectedURL = proxySnapshot
            result = await probeConfiguredURL(selectedURL, missingMessage: "Remote proxy URL is empty", mode: modeSnapshot)
        case .auto:
            if let winner = await fastestRespondingProbe(
                local:     localSnapshot,
                tailscale: tailscaleSnapshot,
                proxy:     proxySnapshot
            ) {
                selectedURL = winner.url
                result = winner
            } else {
                selectedURL = firstConfiguredURL(local: localSnapshot, tailscale: tailscaleSnapshot, proxy: proxySnapshot)
                // fastestRespondingProbe returns nil in two cases:
                //  1. All probes failed → it already updated lastProbeResult with the
                //     failure result, so using lastProbeResult here is correct.
                //  2. No URLs were configured → no probes ran, lastProbeResult was NOT
                //     updated and may still hold a stale success from a previous run.
                //     In that case selectedURL is also empty, so we nil out result to
                //     force the "No server configured" path below.
                result = selectedURL.isEmpty ? nil : lastProbeResult
            }
        }

        guard !Task.isCancelled else { return }

        if let result, result.isSuccess {
            selectedURL = result.url
        }
        // BUG FIX: capture previousURL BEFORE overwriting currentURL.
        // Previously it was set after the assignment, making
        // selectedURL != previousURL always false and the PlaybackHistoryStore
        // cache-invalidation path dead code.
        let previousURL = currentURL
        currentURL = selectedURL
        LyrionAPI.shared.updateBaseURL(selectedURL, persist: false)

        // Invalidate the in-memory playback history cache whenever the active
        // server changes so a different LMS library gets a fresh history slot.
        // Also cancel any pending debounced state save — we don't want to write
        // state for the old server under the new server's storage key.
        if selectedURL != previousURL {
            PlaybackHistoryStore.shared.invalidateCache()
            PlaybackStateStore.shared.cancelPendingSave()
            LibraryViewModel.shared.clearCache()
            ArtworkCache.shared.clear(includeDiskCache: true)
            ServerLogStore.shared.info("Cleared library, playback-state, and artwork caches after active server changed")
        }

        if let result {
            lastProbeResult = result
            isConnected = result.isSuccess
            lastConnectionMessage = result.summary
            if result.isSuccess {
                ServerLogStore.shared.info(result.summary)
            } else {
                ServerLogStore.shared.warn(result.summary)
            }
        } else {
            isConnected = false
            lastConnectionMessage = selectedURL.isEmpty ? "No server configured" : "No server responded"
            ServerLogStore.shared.warn(lastConnectionMessage)
        }
    }

    private func probeConfiguredURL(_ url: String, missingMessage: String, mode: ConnectionMode) async -> ConnectionProbeResult? {
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Return a normal probe result instead of mutating connection state here.
            // performResolve() owns state transitions and server-change invalidation.
            ServerLogStore.shared.warn(missingMessage)
            return ConnectionProbeResult(
                url: "",
                endpoint: "",
                startedAt: Date(),
                duration: 0,
                statusCode: nil,
                serverVersion: nil,
                errorMessage: missingMessage
            )
        }
        return await Self.probeBestServer(url, mode: mode)
    }

    private func fastestRespondingProbe(
        local: String? = nil,
        tailscale: String? = nil,
        proxy: String? = nil
    ) async -> ConnectionProbeResult? {
        let candidates = uniqueCandidateURLs(local: local, tailscale: tailscale, proxy: proxy)
        guard !candidates.isEmpty else { return nil }

        ServerLogStore.shared.debug("Auto candidates: \(candidates.map(displayURL).joined(separator: ", "))")
        let result = await Self.probeFirstSuccessful(candidates: candidates)
        if let result, !result.isSuccess {
            lastProbeResult = result
            lastConnectionMessage = result.summary
            return nil
        }
        return result
    }

    nonisolated static func probeBestServer(_ url: String, mode: ConnectionMode? = nil) async -> ConnectionProbeResult {
        let candidates = HyperionServerURL.candidateBases(for: url, mode: mode)
        guard !candidates.isEmpty else { return await probeServer("") }
        await ServerLogStore.shared.debug("Probe candidates: \(candidates.map(ServerLogStore.redactedURL).joined(separator: ", "))")
        if let result = await probeFirstSuccessful(candidates: candidates) {
            return result
        }
        return await probeServer("")
    }

    nonisolated static func probeFirstSuccessful(candidates: [String]) async -> ConnectionProbeResult? {
        guard !candidates.isEmpty else { return nil }

        // One shared ephemeral session for the whole race.  Creating a new
        // URLSession per probe candidate multiplies socket overhead; this
        // single session is invalidated when the group finishes.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity       = false
        config.requestCachePolicy         = .reloadIgnoringLocalCacheData
        let sharedSession = URLSession(configuration: config)

        var lastFailure: ConnectionProbeResult?
        let result = await withTaskGroup(of: ConnectionProbeResult.self, returning: ConnectionProbeResult?.self) { group in
            for url in candidates {
                group.addTask { await Self.probeServer(url, session: sharedSession) }
            }

            for await probe in group {
                if probe.isSuccess {
                    group.cancelAll()
                    return probe
                }
                lastFailure = probe
            }
            return lastFailure
        }

        // Cancel any pending network tasks on the shared session now that the
        // group is done. finishTasksAndInvalidate would wait for them; we want
        // immediate cancellation of losing probes to free sockets quickly.
        sharedSession.invalidateAndCancel()
        return result
    }

    nonisolated func testURL(_ url: String) async -> Bool {
        await Self.probeURL(url)
    }

    nonisolated static func probeURL(_ url: String) async -> Bool {
        await probeBestServer(url).isSuccess
    }

    nonisolated static func probeServer(_ url: String, timeout: TimeInterval = 5, session providedSession: URLSession? = nil) async -> ConnectionProbeResult {
        let started = Date()
        let sanitized = sanitizedURL(url)
        let redacted = ServerLogStore.redactedURL(sanitized)

        guard !sanitized.isEmpty else {
            await ServerLogStore.shared.warn("Probe skipped: blank server URL")
            return ConnectionProbeResult(
                url: "",
                endpoint: "",
                startedAt: started,
                duration: Date().timeIntervalSince(started),
                statusCode: nil,
                serverVersion: nil,
                errorMessage: "Blank server URL"
            )
        }

        guard let requestURL = URL(string: "\(sanitized)/jsonrpc.js") else {
            await ServerLogStore.shared.error("Probe failed: invalid URL \(redacted)")
            return ConnectionProbeResult(
                url: sanitized,
                endpoint: "\(sanitized)/jsonrpc.js",
                startedAt: started,
                duration: Date().timeIntervalSince(started),
                statusCode: nil,
                serverVersion: nil,
                errorMessage: "Invalid URL"
            )
        }

        await ServerLogStore.shared.debug("Probe start: \(ServerLogStore.redactedURL(requestURL.absoluteString))")

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Hyperion iOS", forHTTPHeaderField: "User-Agent")
        HyperionURLAuth.addAuthorizationHeader(to: &request, baseURL: sanitized)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "id":     1,
            "method": "slim.request",
            "params": ["0", ["version", "?"]]
        ])
        request.timeoutInterval = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Reuse a caller-provided session (e.g. from probeFirstSuccessful) to
        // avoid creating a new socket pool for every candidate URL.
        let session: URLSession
        let ownsSession: Bool
        if let provided = providedSession {
            session = provided
            ownsSession = false
        } else {
            session = URLSession(configuration: config)
            ownsSession = true
        }
        defer { if ownsSession { session.finishTasksAndInvalidate() } }

        do {
            let (data, response) = try await session.data(for: request)
            let duration = Date().timeIntervalSince(started)
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode

            var serverVersion: String?
            var errorMessage: String?
            var receivedLyrionJSON = false

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let rpcError = json["error"] as? [String: Any] {
                    let message = rpcError["message"] as? String ?? "JSON-RPC error"
                    let code = rpcError["code"].map { " (RPC \($0))" } ?? ""
                    errorMessage = message + code
                }
                if let result = json["result"] as? [String: Any] {
                    receivedLyrionJSON = true
                    serverVersion = (result["_version"] as? String) ?? (result["version"] as? String)
                }
            }

            if let statusCode, !(200..<300).contains(statusCode) {
                errorMessage = Self.httpStatusMessage(statusCode)
            } else if !receivedLyrionJSON && errorMessage == nil {
                errorMessage = "HTTP response was not Lyrion JSON-RPC"
            }

            let result = ConnectionProbeResult(
                url: sanitized,
                endpoint: requestURL.absoluteString,
                startedAt: started,
                duration: duration,
                statusCode: statusCode,
                serverVersion: serverVersion,
                errorMessage: errorMessage
            )
            await logProbeResult(result)
            return result
        } catch {
            let result = ConnectionProbeResult(
                url: sanitized,
                endpoint: requestURL.absoluteString,
                startedAt: started,
                duration: Date().timeIntervalSince(started),
                statusCode: nil,
                serverVersion: nil,
                errorMessage: Self.describeNetworkError(error)
            )
            if Self.isCancellation(error) {
                await ServerLogStore.shared.debug("Probe cancelled: \(result.summary)")
            } else {
                await logProbeResult(result)
            }
            return result
        }
    }

    func forceReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil

        let old = inFlightResolve
        inFlightResolve = nil
        old?.task.cancel()

        ServerLogStore.shared.info("Manual reconnect requested")
        reconnectTask = Task { await resolveConnection() }
    }

    // MARK: - Helpers

    private func uniqueCandidateURLs(
        local: String? = nil,
        tailscale: String? = nil,
        proxy: String? = nil
    ) -> [String] {
        var seen = Set<String>()
        let entries: [(String, ConnectionMode)] = [
            (local ?? localURL, .local),
            (tailscale ?? tailscaleURL, .tailscale),
            (proxy ?? proxyURL, .proxy)
        ]
        return entries
            .flatMap { HyperionServerURL.candidateBases(for: $0.0, mode: $0.1) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func firstConfiguredURL(local: String, tailscale: String, proxy: String) -> String {
        let entries: [(String, ConnectionMode)] = [(local, .local), (tailscale, .tailscale), (proxy, .proxy)]
        for (value, mode) in entries {
            if let first = HyperionServerURL.candidateBases(for: value, mode: mode).first, !first.isEmpty {
                return first
            }
        }
        return ""
    }

    private func resolvedURLForCurrentMode() -> String {
        switch connectionMode {
        case .local:
            return HyperionServerURL.candidateBases(for: localURL, mode: .local).first ?? Self.sanitizedURL(localURL)
        case .tailscale:
            return HyperionServerURL.candidateBases(for: tailscaleURL, mode: .tailscale).first ?? Self.sanitizedURL(tailscaleURL)
        case .proxy:
            return HyperionServerURL.candidateBases(for: proxyURL, mode: .proxy).first ?? Self.sanitizedURL(proxyURL)
        case .auto:
            return firstConfiguredURL(local: localURL, tailscale: tailscaleURL, proxy: proxyURL)
        }
    }

    private nonisolated static func sanitizedURL(_ url: String) -> String {
        HyperionServerURL.sanitizedBase(url)
    }

    private typealias URLConnectionKind = HyperionServerURL.URLConnectionKind

    private nonisolated static func connectionKind(for rawURL: String) -> URLConnectionKind {
        HyperionServerURL.connectionKind(for: rawURL)
    }

    private func displayURL(_ url: String) -> String {
        HyperionServerURL.redactedDisplay(url)
    }

    private nonisolated static func pathSummary(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "online"
        case .unsatisfied: status = "offline"
        case .requiresConnection: status = "requires connection"
        @unknown default: status = "unknown"
        }

        var parts = [status]
        if path.usesInterfaceType(.wifi) { parts.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { parts.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("ethernet") }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("low-data") }
        return parts.joined(separator: ", ")
    }

    private nonisolated static func httpStatusMessage(_ status: Int) -> String {
        switch status {
        case 401: return "HTTP 401 Unauthorized — check proxy authentication"
        case 403: return "HTTP 403 Forbidden — proxy denied the request"
        case 404: return "HTTP 404 Not Found — check the proxy path to /jsonrpc.js"
        case 502: return "HTTP 502 Bad Gateway — proxy cannot reach Lyrion"
        case 503: return "HTTP 503 Service Unavailable — upstream server is unavailable"
        case 504: return "HTTP 504 Gateway Timeout — proxy timed out reaching Lyrion"
        default:  return "HTTP \(status)"
        }
    }

    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private nonisolated static func describeNetworkError(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut:
            return "Timed out"
        case .cannotFindHost, .dnsLookupFailed:
            return "DNS failed — host not found"
        case .cannotConnectToHost:
            return "Cannot connect to host"
        case .networkConnectionLost:
            return "Network connection lost"
        case .notConnectedToInternet:
            return "No internet connection"
        case .appTransportSecurityRequiresSecureConnection:
            return "Blocked by App Transport Security — remote HTTP needs an ATS-enabled build, HTTPS reverse proxy, or Tailscale. Public http://:9000 is not recommended."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "TLS/certificate failure"
        default:
            return urlError.localizedDescription
        }
    }

    private nonisolated static func logProbeResult(_ result: ConnectionProbeResult) async {
        if result.isSuccess {
            await ServerLogStore.shared.info("Probe OK: \(result.summary)")
        } else {
            await ServerLogStore.shared.warn("Probe failed: \(result.summary)")
        }
    }
}
