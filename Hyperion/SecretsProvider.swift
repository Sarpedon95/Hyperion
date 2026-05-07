import Foundation

// Reads API keys injected via Secrets.xcconfig → Info.plist at build time.
// If a key is absent (e.g. the xcconfig is not wired into the Xcode project yet)
// it falls back to the legacy hardcoded value so existing builds keep working.
enum SecretsProvider {
    static var lastFmApiKey: String {
        Bundle.main.infoDictionary?["LASTFM_API_KEY"] as? String ?? "1f3fd89f88c37df99a6dbc3a06b21642"
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
