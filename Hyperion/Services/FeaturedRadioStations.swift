import Foundation

// MARK: - Featured radio stations
//
// A curated list of UK stations that always appear in the Radio tab, even if
// RadioBrowser is unreachable. Each seed carries a best-effort fallback stream
// URL plus a brand colour. At runtime RadioViewModel refreshes each station's
// stream URL via RadioBrowserAPI.bestMatch(name:) (taking the highest-vote
// url_resolved), so the fallback URLs only matter when the API is unavailable.
//
// Sort order: BBC stations first (in the order below), then alphabetical.

enum FeaturedRadioStations {

    struct Seed {
        let name: String
        let fallbackURL: String
        let brandHex: String
        let isBBC: Bool
        let genre: String?
    }

    // Best-effort fallback stream URLs — refreshed at runtime via RadioBrowser.
    static let seeds: [Seed] = [
        // BBC family (#BB1919) — listed first.
        Seed(name: "BBC Radio 1",       fallbackURL: "https://stream.live.vc.bbcmedia.co.uk/bbc_radio_one",     brandHex: "#BB1919", isBBC: true, genre: "Pop"),
        Seed(name: "BBC Radio 2",       fallbackURL: "https://stream.live.vc.bbcmedia.co.uk/bbc_radio_two",     brandHex: "#BB1919", isBBC: true, genre: "Adult Contemporary"),
        Seed(name: "BBC Radio 3",       fallbackURL: "https://stream.live.vc.bbcmedia.co.uk/bbc_radio_three",   brandHex: "#BB1919", isBBC: true, genre: "Classical"),
        Seed(name: "BBC Radio 4",       fallbackURL: "https://stream.live.vc.bbcmedia.co.uk/bbc_radio_fourfm",  brandHex: "#BB1919", isBBC: true, genre: "News"),
        Seed(name: "BBC Radio 6 Music", fallbackURL: "https://stream.live.vc.bbcmedia.co.uk/bbc_6music",        brandHex: "#BB1919", isBBC: true, genre: "Alternative"),
        Seed(name: "BBC World Service", fallbackURL: "https://stream.live.vc.bbcmedia.co.uk/bbc_world_service",  brandHex: "#BB1919", isBBC: true, genre: "News"),

        // Commercial UK stations — alphabetical.
        Seed(name: "Absolute Radio",  fallbackURL: "https://stream-al.planetradio.co.uk/absoluteradio.aac",    brandHex: "#E2231A", isBBC: false, genre: "Rock"),
        Seed(name: "Capital FM",      fallbackURL: "https://media-ssl.musicradio.com/CapitalMP3",              brandHex: "#F0508C", isBBC: false, genre: "Pop"),
        Seed(name: "Classic FM",      fallbackURL: "https://media-ssl.musicradio.com/ClassicFMMP3",            brandHex: "#8B1F7A", isBBC: false, genre: "Classical"),
        Seed(name: "Heart FM",        fallbackURL: "https://media-ssl.musicradio.com/HeartLondon",             brandHex: "#E5226B", isBBC: false, genre: "Pop"),
        Seed(name: "Jazz FM",         fallbackURL: "https://edge-bauerall-01-gos2.sharp-stream.com/jazz.mp3",  brandHex: "#1F6FB2", isBBC: false, genre: "Jazz"),
        Seed(name: "Kiss FM UK",      fallbackURL: "https://stream-mz.planetradio.co.uk/kissnational.aac",     brandHex: "#E6007E", isBBC: false, genre: "Dance"),
        Seed(name: "LBC",             fallbackURL: "https://media-ssl.musicradio.com/LBCUK",                   brandHex: "#0A2342", isBBC: false, genre: "News"),
        Seed(name: "NTS Radio 1",     fallbackURL: "https://stream-relay-geo.ntslive.net/stream",              brandHex: "#111111", isBBC: false, genre: "Eclectic"),
        Seed(name: "Planet Rock",     fallbackURL: "https://stream-mz.planetradio.co.uk/planetrock.aac",       brandHex: "#C8102E", isBBC: false, genre: "Rock"),
        Seed(name: "Radio X",         fallbackURL: "https://media-ssl.musicradio.com/RadioXUK",                brandHex: "#231F20", isBBC: false, genre: "Indie"),
        Seed(name: "Rinse FM",        fallbackURL: "https://admin.stream.rinse.fm/proxy/rinse_uk/stream",      brandHex: "#000000", isBBC: false, genre: "Electronic"),
        Seed(name: "Smooth Radio UK", fallbackURL: "https://media-ssl.musicradio.com/SmoothUK",                brandHex: "#7B2D8B", isBBC: false, genre: "Easy Listening"),
        Seed(name: "talkSPORT",       fallbackURL: "https://radio.talksport.com/stream",                       brandHex: "#0B5C2E", isBBC: false, genre: "Sport"),
        Seed(name: "Virgin Radio UK", fallbackURL: "https://radio.virginradio.co.uk/stream",                   brandHex: "#E4002B", isBBC: false, genre: "Pop")
    ]

    /// Featured stations built from the fallback URLs. Always available even
    /// offline; RadioViewModel refreshes the stream URLs via RadioBrowser.
    static func stations() -> [RadioStation] {
        seeds.compactMap { seed in
            guard let url = URL(string: seed.fallbackURL) else { return nil }
            return RadioStation(
                id:        "featured:\(seed.name)",
                name:      seed.name,
                streamURL: url,
                genre:     seed.genre,
                country:   "United Kingdom",
                language:  "english",
                logoURL:   nil,
                bitrate:   nil,
                codec:     nil,
                votes:     nil,
                isFeatured: true
            )
        }
    }

    /// Brand colour hex for a featured station name (matched case-insensitively).
    static func brandHex(for stationName: String) -> String? {
        seeds.first { $0.name.compare(stationName, options: .caseInsensitive) == .orderedSame }?.brandHex
    }
}
