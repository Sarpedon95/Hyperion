import Foundation

// AUDIT-FIX #5 — API keys are injected via Secrets.xcconfig → Info.plist at build time.
// No hardcoded fallback keys; absent keys return "" so callers can show a
// "not configured" state rather than silently using an embedded secret.
enum SecretsProvider {
    static var lastFmApiKey: String {
        Bundle.main.infoDictionary?["LASTFM_API_KEY"] as? String ?? ""
    }

    static var lastFmSharedSecret: String {
        Bundle.main.infoDictionary?["LASTFM_SHARED_SECRET"] as? String ?? ""
    }

    static var discogsConsumerKey: String {
        Bundle.main.infoDictionary?["DISCOGS_CONSUMER_KEY"] as? String ?? ""
    }

    static var discogsConsumerSecret: String {
        Bundle.main.infoDictionary?["DISCOGS_CONSUMER_SECRET"] as? String ?? ""
    }
}
