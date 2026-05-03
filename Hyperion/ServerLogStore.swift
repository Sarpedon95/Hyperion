import Combine
import Foundation
import os

struct ServerLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: ServerLogLevel
    let message: String

    var displayTime: String {
        timestamp.formatted(Self.timeStyle)
    }

    // PERF: Compute the format style once (it has non-trivial allocation cost).
    private static let timeStyle = Date.FormatStyle()
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)

    var displayLine: String {
        "[\(displayTime)] \(level.rawValue): \(message)"
    }
}

enum ServerLogLevel: String, Equatable {
    case debug = "DEBUG"
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"
}

@MainActor
final class ServerLogStore: ObservableObject {
    static let shared = ServerLogStore()

    @Published private(set) var entries: [ServerLogEntry] = []

    private let maxEntries = 250
    private let logger = Logger(subsystem: "com.sarpedon.hyperion", category: "Server")

    private init() {}

    func debug(_ message: String) { append(level: .debug, message: message) }
    func info(_ message: String)  { append(level: .info,  message: message) }
    func warn(_ message: String)  { append(level: .warn,  message: message) }
    func error(_ message: String) { append(level: .error, message: message) }

    func clear() {
        entries.removeAll()
        logger.info("Server diagnostics cleared")
    }

    var exportText: String {
        entries.map(\.displayLine).joined(separator: "\n")
    }

    nonisolated static func redactedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }

    private func append(level: ServerLogLevel, message: String) {
        let entry = ServerLogEntry(timestamp: Date(), level: level, message: message)
        entries.append(entry)
        // PERF: Replace the entire array with a slice rather than calling
        // removeFirst(_:) which shifts every remaining element. This is O(1)
        // for the slice + O(n) for the Array init, same asymptotic cost but
        // avoids the repeated element-shift overhead of removeFirst.
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }

        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warn:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}
