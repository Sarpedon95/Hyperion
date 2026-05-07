import Foundation

// MARK: - Discogs Personal Access Token Manager

@MainActor
final class DiscogsAuthManager: ObservableObject {

    static let shared = DiscogsAuthManager()

    @Published private(set) var accessToken: String? = nil
    @Published var isConnected: Bool = false

    private static let keychainKey = "discogs.accessToken"

    private init() {
        accessToken = KeychainManager.shared.load(key: Self.keychainKey)
        isConnected = accessToken != nil
    }

    func connect(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accessToken = trimmed
        isConnected = true
        KeychainManager.shared.save(key: Self.keychainKey, value: trimmed)
    }

    func disconnect() {
        accessToken = nil
        isConnected = false
        KeychainManager.shared.delete(key: Self.keychainKey)
    }

    /// Returns the token to use in API requests, or nil if not authenticated.
    var token: String? { accessToken }
}
