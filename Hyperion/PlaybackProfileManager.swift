import Foundation

/// Resolves the active PlaybackProfile and its settings for the current context.
///
/// Resolution order (highest priority first):
///   1. Manual override stored per album-ID key in UserDefaults
///   2. Genre auto-detection from the current track's genres field
///   3. Global default profile (user-selectable in Settings)
///
/// Session-level overrides are ephemeral — they let the user tweak a single
/// toggle in the Now Playing sheet without persisting to the profile settings.
/// They are cleared whenever a new queue starts (call `clearSessionOverrides()`).
@MainActor
final class PlaybackProfileManager: ObservableObject {

    static let shared = PlaybackProfileManager()

    // MARK: - Resolved state

    @Published private(set) var activeProfile:   PlaybackProfile       = .standard
    @Published private(set) var detectionSource: ProfileDetectionSource = .globalDefault

    // MARK: - Session overrides (nil = use profile/settings value)

    @Published var sessionGaplessEnabled:    Bool?            = nil
    @Published var sessionCrossfadeEnabled:  Bool?            = nil
    @Published var sessionCrossfadeDuration: Double?          = nil
    @Published var sessionCrossfeedEnabled:  Bool?            = nil
    @Published var sessionCrossfeedPreset:   CrossfeedPreset? = nil
    @Published var sessionInterTrackGap:     InterTrackGap?   = nil

    // MARK: - Global default (persisted)

    @Published var globalDefaultProfile: PlaybackProfile = {
        let raw = UserDefaults.standard.string(forKey: "hyperion.profile.global") ?? ""
        return PlaybackProfile(rawValue: raw) ?? .standard
    }() {
        didSet {
            UserDefaults.standard.set(globalDefaultProfile.rawValue, forKey: "hyperion.profile.global")
        }
    }

    // MARK: - Per-profile settings (persisted)

    @Published var profileSettings: [String: ProfileSettings] = {
        guard let data = UserDefaults.standard.data(forKey: "hyperion.profile.settings_v1"),
              let d    = try? JSONDecoder().decode([String: ProfileSettings].self, from: data)
        else { return [:] }
        return d
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(profileSettings) {
                UserDefaults.standard.set(data, forKey: "hyperion.profile.settings_v1")
            }
        }
    }

    // MARK: - Manual overrides (persisted, keyed by "album:<albumID>")

    private var manualOverrides: [String: PlaybackProfile] = {
        guard let data = UserDefaults.standard.data(forKey: "hyperion.profile.overrides_v1"),
              let d    = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return d.compactMapValues { PlaybackProfile(rawValue: $0) }
    }()

    // MARK: - Resolved computed values

    var resolvedSettings: ProfileSettings {
        profileSettings[activeProfile.rawValue] ?? ProfileSettings.defaults(for: activeProfile)
    }

    var resolvedGaplessEnabled: Bool {
        sessionGaplessEnabled ?? resolvedSettings.gaplessEnabled
    }

    /// Crossfade and inter-track gap are mutually exclusive — if gap > 0, crossfade is suppressed.
    var resolvedCrossfadeEnabled: Bool {
        guard resolvedInterTrackGap == .none else { return false }
        return sessionCrossfadeEnabled ?? resolvedSettings.crossfadeEnabled
    }

    var resolvedCrossfadeDuration: Double {
        sessionCrossfadeDuration ?? resolvedSettings.crossfadeDuration
    }

    var resolvedCrossfadeShape: CrossfadeShape {
        resolvedSettings.crossfadeShape
    }

    var resolvedCrossfeedEnabled: Bool {
        sessionCrossfeedEnabled ?? resolvedSettings.crossfeedEnabled
    }

    var resolvedCrossfeedPreset: CrossfeedPreset {
        sessionCrossfeedPreset ?? resolvedSettings.crossfeedPreset
    }

    /// Inter-track gap is suppressed when gapless is active.
    var resolvedInterTrackGap: InterTrackGap {
        guard !resolvedGaplessEnabled else { return .none }
        return sessionInterTrackGap ?? resolvedSettings.interTrackGap
    }

    var resolvedSampleRateConversionEnabled: Bool {
        resolvedSettings.sampleRateConversionEnabled
    }

    // MARK: - Profile resolution

    /// Update the active profile from the current track's genre metadata.
    /// Call this at the start of each new track.
    func update(for track: Track?) {
        if let key = track.flatMap({ albumKey(for: $0) }),
           let manual = manualOverrides[key] {
            activeProfile   = manual
            detectionSource = .manual
            return
        }
        let detected = PlaybackProfile.autoDetect(from: track?.genres)
        if detected != .standard {
            activeProfile   = detected
            detectionSource = .auto
        } else {
            activeProfile   = globalDefaultProfile
            detectionSource = .globalDefault
        }
    }

    // MARK: - Manual override

    func setManualOverride(_ profile: PlaybackProfile, for track: Track?) {
        if let key = track.flatMap({ albumKey(for: $0) }) {
            manualOverrides[key] = profile
            saveOverrides()
        }
        activeProfile   = profile
        detectionSource = .manual
    }

    func clearManualOverride(for track: Track?) {
        guard let key = track.flatMap({ albumKey(for: $0) }) else { return }
        manualOverrides.removeValue(forKey: key)
        saveOverrides()
    }

    // MARK: - Per-profile settings

    func settings(for profile: PlaybackProfile) -> ProfileSettings {
        profileSettings[profile.rawValue] ?? ProfileSettings.defaults(for: profile)
    }

    func updateSettings(for profile: PlaybackProfile, _ mutation: (inout ProfileSettings) -> Void) {
        var s = settings(for: profile)
        mutation(&s)
        profileSettings[profile.rawValue] = s
    }

    // MARK: - Session overrides

    func clearSessionOverrides() {
        sessionGaplessEnabled    = nil
        sessionCrossfadeEnabled  = nil
        sessionCrossfadeDuration = nil
        sessionCrossfeedEnabled  = nil
        sessionCrossfeedPreset   = nil
        sessionInterTrackGap     = nil
    }

    // MARK: - Display helpers

    func pillLabel(profile: PlaybackProfile, source: ProfileDetectionSource) -> String {
        let src = source.label
        return src.isEmpty ? profile.displayName : "\(profile.displayName) (\(src))"
    }

    // MARK: - Private

    private init() {}

    private func albumKey(for track: Track) -> String? {
        guard let albumID = track.albumID else { return nil }
        return "album:\(albumID)"
    }

    private func saveOverrides() {
        let raw = manualOverrides.mapValues { $0.rawValue }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: "hyperion.profile.overrides_v1")
        }
    }
}
