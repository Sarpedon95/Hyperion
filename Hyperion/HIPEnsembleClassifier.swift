import Foundation

// Classifies recordings as Historically Informed Performance (HIP) by matching
// conductor and ensemble names against a curated list.
//
// Matching rules:
//   - Diacritic- and case-insensitive (via SearchTextNormalizer.folded)
//   - A built-in entry matches only if the entire phrase appears contiguously
//     inside the candidate string (not word-boundary gated).
//   - User-added entries from Settings follow the same rule.

struct HIPEnsembleClassifier {

    static let shared = HIPEnsembleClassifier()
    private init() {
        #if DEBUG
        HIPEnsembleClassifier.runSelfTest(using: self)
        #endif
    }

    // Each entry is the full phrase that must appear contiguously in the
    // folded candidate string. Short last-names only where collision risk is low.
    private let defaultEntries: [String] = [
        // Conductors
        "harnoncourt", "nikolaus harnoncourt",
        "john eliot gardiner",
        "herreweghe", "philippe herreweghe",
        "norrington", "roger norrington",
        "brüggen", "bruggen",
        "savall", "jordi savall",
        "william christie",
        "pinnock",
        "ton koopman",
        "parrott", "andrew parrott",
        "hogwood", "christopher hogwood",
        "minkowski",
        "mcreesh",
        "suzuki",
        "bernius",
        "bolton",
        "labadie",
        "malgoire",
        "leonhardt",
        "bilson",
        "van asperen",
        "richard egarr",
        "harry christophers",
        "ottavio dantone",
        "fabio biondi",
        "rinaldo alessandrini",
        "christophe rousset",
        // Ensembles (multi-word phrases must be contiguous)
        "english concert",
        "orchestra of the age of enlightenment",
        "collegium vocale",
        "les arts florissants",
        "il giardino armonico",
        "freiburger barockorchester",
        "academy of ancient music",
        "musica antiqua köln",
        "musica antiqua koln",
        "the sixteen",
        "taverner players",
        "amsterdam baroque",
        "bach collegium japan",
        "ensemble 415",
        "les musiciens du louvre",
        "le concert spirituel",
        "la chapelle royale",
        "la petite bande",
        "musica antiqua",
        "the hanover band",
        "london baroque",
        "boston baroque",
        "tafelmusik",
        "concerto köln",
        "concerto koln",
        "il complesso barocco",
        "europa galante",
        "concerto italiano",
        "les talens lyriques",
        "scholars baroque ensemble",
        "musica reservata",
        "l'arpa festante",
    ]

    private let userDefaultsKey = "hip.ensembles.custom"

    var userNames: [String] {
        get { UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }

    func isHIP(conductor: String?, band: String?, performerSummary: String?) -> Bool {
        let candidates = [conductor, band, performerSummary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return false }

        let allEntries = (defaultEntries + userNames).map { SearchTextNormalizer.folded($0) }

        return candidates.contains { candidate in
            let foldedCandidate = SearchTextNormalizer.folded(candidate)
            return allEntries.contains { foldedCandidate.contains($0) }
        }
    }

    // MARK: - Debug Self-Test

    #if DEBUG
    // Receives the already-constructed instance to avoid accessing `shared`
    // during its own initialization (which would deadlock on the dispatch_once).
    private static func runSelfTest(using cls: HIPEnsembleClassifier) {
        func check(_ c: String?, _ b: String?, _ s: String?, _ expected: Bool, _ label: String) {
            let result = cls.isHIP(conductor: c, band: b, performerSummary: s)
            if result != expected {
                print("⚠️ HIPEnsembleClassifier self-test FAILED: \(label) — expected \(expected), got \(result)")
            }
        }

        // True positives
        check("Nikolaus Harnoncourt", nil, nil, true, "Harnoncourt full name")
        check("John Eliot Gardiner", nil, nil, true, "Gardiner full name")
        check(nil, "Les Arts Florissants", nil, true, "Les Arts Florissants")
        check(nil, "Freiburger Barockorchester", nil, true, "Freiburger Barockorchester")
        check(nil, "Bach Collegium Japan", nil, true, "Bach Collegium Japan")
        check("Philippe Herreweghe", nil, nil, true, "Herreweghe with diacritic")
        check(nil, "Musica Antiqua Köln", nil, true, "Musica Antiqua Köln diacritic")
        check(nil, nil, "Jordi Savall, La Capella Reial", true, "Savall in performer summary")
        check(nil, "Boston Baroque", nil, true, "Boston Baroque")

        // True negatives
        check("Simon Rattle", nil, nil, false, "Simon Rattle not HIP")
        check("Baroque Music Fans", nil, nil, false, "'baroque' substring must not fire")
        check("The Beatles", nil, nil, false, "The Beatles")
        check("Thomas", nil, nil, false, "Common short name")
        check(nil, "Boston Symphony Orchestra", nil, false, "BSO — not Boston Baroque")
        check("John Gardiner", nil, nil, false, "Partial name — must match 'john eliot gardiner' fully")
        check(nil, nil, nil, false, "All nil")
    }
    #endif
}
