import AVFoundation
import Combine
import CoreBluetooth
import Foundation

// MARK: - EQ Filter Type

enum EQFilterType: String, Codable, CaseIterable, Identifiable {
    case peak      = "Peak"
    case lowShelf  = "Low Shelf"
    case highShelf = "High Shelf"
    case lowPass   = "Low Pass"
    case highPass  = "High Pass"

    var id: String { rawValue }

    var avType: AVAudioUnitEQFilterType {
        switch self {
        case .peak:      return .parametric
        case .lowShelf:  return .lowShelf
        case .highShelf: return .highShelf
        case .lowPass:   return .lowPass
        case .highPass:  return .highPass
        }
    }
}

// MARK: - EQ Band

struct OrpheusEQBand: Codable, Identifiable, Hashable {
    var id: UUID       = UUID()
    var filterType: EQFilterType = .peak
    var frequency: Float = 1000   // Hz
    var gain: Float      = 0      // dB, −12…+12
    var bandwidth: Float = 1.0    // Q / octave width
    var isActive: Bool   = true
}

// MARK: - Supporting enums

enum VolumeLevelingMode: String, Codable, CaseIterable, Identifiable {
    case auto   = "Auto"
    case manual = "Manual"
    var id: String { rawValue }
}

enum SRCMode: String, Codable, CaseIterable, Identifiable {
    case compatibilityOnly = "For Compatibility Only"
    case always            = "Always"
    case never             = "Never"
    var id: String { rawValue }
}

enum HeadroomMode: String, Codable, CaseIterable, Identifiable {
    case auto   = "Auto"
    case manual = "Manual"
    var id: String { rawValue }
}

// MARK: - Preset

struct OrpheusPreset: Codable, Identifiable, Hashable {
    var id: UUID       = UUID()
    var name: String
    var deviceName: String?

    var mainEQBands:           [OrpheusEQBand]
    var mainEQBypassed:        Bool
    var headphoneEQBands:      [OrpheusEQBand]
    var headphoneEQBypassed:   Bool
    var crossfeedFrequency:    Float
    var crossfeedLevel:        Float
    var crossfeedDelay:        Float
    var crossfeedBypassed:     Bool
    var volumeLevelingMode:    VolumeLevelingMode
    var volumeLevelingTargetLUFS: Float
    var volumeLevelingBypassed:  Bool
    var balanceLeft:           Float
    var balanceRight:          Float
    var balanceMono:           Bool
    var balanceBypassed:       Bool
    var srcMode:               SRCMode
    var headroomMode:          HeadroomMode
    var headroomManualDB:      Float
    var headroomBypassed:      Bool

    // Memberwise init — used when creating presets programmatically.
    init(name: String, deviceName: String? = nil,
         mainEQBands: [OrpheusEQBand], mainEQBypassed: Bool,
         headphoneEQBands: [OrpheusEQBand], headphoneEQBypassed: Bool,
         crossfeedFrequency: Float, crossfeedLevel: Float, crossfeedDelay: Float, crossfeedBypassed: Bool,
         volumeLevelingMode: VolumeLevelingMode, volumeLevelingTargetLUFS: Float, volumeLevelingBypassed: Bool,
         balanceLeft: Float, balanceRight: Float, balanceMono: Bool, balanceBypassed: Bool,
         srcMode: SRCMode, headroomMode: HeadroomMode, headroomManualDB: Float, headroomBypassed: Bool) {
        self.name                     = name
        self.deviceName               = deviceName
        self.mainEQBands              = mainEQBands
        self.mainEQBypassed           = mainEQBypassed
        self.headphoneEQBands         = headphoneEQBands
        self.headphoneEQBypassed      = headphoneEQBypassed
        self.crossfeedFrequency       = crossfeedFrequency
        self.crossfeedLevel           = crossfeedLevel
        self.crossfeedDelay           = crossfeedDelay
        self.crossfeedBypassed        = crossfeedBypassed
        self.volumeLevelingMode       = volumeLevelingMode
        self.volumeLevelingTargetLUFS = volumeLevelingTargetLUFS
        self.volumeLevelingBypassed   = volumeLevelingBypassed
        self.balanceLeft              = balanceLeft
        self.balanceRight             = balanceRight
        self.balanceMono              = balanceMono
        self.balanceBypassed          = balanceBypassed
        self.srcMode                  = srcMode
        self.headroomMode             = headroomMode
        self.headroomManualDB         = headroomManualDB
        self.headroomBypassed         = headroomBypassed
    }

    // Custom decoder provides default for crossfeedDelay so old saved presets decode cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                       = (try? c.decode(UUID.self,              forKey: .id))              ?? UUID()
        name                     = try  c.decode(String.self,             forKey: .name)
        deviceName               = try? c.decode(String.self,             forKey: .deviceName)
        mainEQBands              = try  c.decode([OrpheusEQBand].self,    forKey: .mainEQBands)
        mainEQBypassed           = try  c.decode(Bool.self,               forKey: .mainEQBypassed)
        headphoneEQBands         = try  c.decode([OrpheusEQBand].self,    forKey: .headphoneEQBands)
        headphoneEQBypassed      = try  c.decode(Bool.self,               forKey: .headphoneEQBypassed)
        crossfeedFrequency       = try  c.decode(Float.self,              forKey: .crossfeedFrequency)
        crossfeedLevel           = try  c.decode(Float.self,              forKey: .crossfeedLevel)
        crossfeedDelay           = (try? c.decode(Float.self,             forKey: .crossfeedDelay))  ?? 0.3
        crossfeedBypassed        = try  c.decode(Bool.self,               forKey: .crossfeedBypassed)
        volumeLevelingMode       = try  c.decode(VolumeLevelingMode.self, forKey: .volumeLevelingMode)
        volumeLevelingTargetLUFS = try  c.decode(Float.self,              forKey: .volumeLevelingTargetLUFS)
        volumeLevelingBypassed   = try  c.decode(Bool.self,               forKey: .volumeLevelingBypassed)
        balanceLeft              = try  c.decode(Float.self,              forKey: .balanceLeft)
        balanceRight             = try  c.decode(Float.self,              forKey: .balanceRight)
        balanceMono              = try  c.decode(Bool.self,               forKey: .balanceMono)
        balanceBypassed          = try  c.decode(Bool.self,               forKey: .balanceBypassed)
        srcMode                  = try  c.decode(SRCMode.self,            forKey: .srcMode)
        headroomMode             = try  c.decode(HeadroomMode.self,       forKey: .headroomMode)
        headroomManualDB         = try  c.decode(Float.self,              forKey: .headroomManualDB)
        headroomBypassed         = try  c.decode(Bool.self,               forKey: .headroomBypassed)
    }
}

// MARK: - DSP Engine

@MainActor
final class OrpheusDSPEngine: NSObject, ObservableObject {

    static let shared = OrpheusDSPEngine()

    private let audioManager = AudioPlayerManager.shared

    // MARK: Main EQ
    @Published var mainEQBands: [OrpheusEQBand]   = OrpheusDSPEngine.defaultEQBands()
    @Published var mainEQBypassed: Bool             = false

    // MARK: Headphone EQ
    @Published var headphoneEQBands: [OrpheusEQBand] = OrpheusDSPEngine.defaultEQBands()
    @Published var headphoneEQBypassed: Bool           = false

    // MARK: Crossfeed
    @Published var crossfeedFrequency: Float = 700   // Hz (LPF cutoff)
    @Published var crossfeedLevel: Float     = 0.45  // strength 0…1
    @Published var crossfeedDelay: Float     = 0.3   // ms ITD
    @Published var crossfeedBypassed: Bool   = false

    // Driven by PlaybackProfileManager — bypasses crossfeed for non-classical profiles
    // without touching the user's permanent crossfeedBypassed setting. Defaults true
    // (bypassed) until a profile with crossfeedEnabled=true is resolved.
    @Published var profileDrivenCrossfeedBypassed: Bool = true {
        didSet { applyCrossfeed() }
    }

    // True when the current audio output is wired or Bluetooth headphones.
    // Crossfeed is auto-bypassed for speaker / AirPlay / line output.
    @Published private(set) var isHeadphoneOutput: Bool = false

    // MARK: Volume Leveling
    @Published var volumeLevelingMode: VolumeLevelingMode = .auto
    @Published var volumeLevelingTargetLUFS: Float         = -14  // −23…−9
    @Published var volumeLevelingBypassed: Bool            = false

    // MARK: Balance
    @Published var balanceLeft: Float   = 0    // −6…+6 dB
    @Published var balanceRight: Float  = 0
    @Published var balanceMono: Bool    = false
    @Published var balanceBypassed: Bool = false

    // MARK: SRC
    @Published var srcMode: SRCMode = .compatibilityOnly

    // MARK: Headroom
    @Published var headroomMode: HeadroomMode = .auto
    @Published var headroomManualDB: Float     = -3   // −3…0
    @Published var headroomBypassed: Bool      = false

    // MARK: Presets
    @Published var presets: [OrpheusPreset]  = []
    @Published var activePresetID: UUID?     = nil

    // MARK: Pure Mode
    /// When true, all intentional Orpheus DSP processing is bypassed on the live
    /// AVAudioEngine graph. Saved EQ/DSP settings are preserved unchanged.
    /// Pure Mode is a temporary processing state, not a destructive reset.
    @Published var isPureModeEnabled: Bool = UserDefaults.standard.bool(forKey: "hyperion.orpheus.pureMode") {
        didSet { UserDefaults.standard.set(isPureModeEnabled, forKey: "hyperion.orpheus.pureMode") }
    }

    // MARK: Bluetooth auto-switch
    @Published var connectedBluetoothDeviceName: String? = nil

    private var centralManager: CBCentralManager?
    private var saveDebounceTask: Task<Void, Never>?

    private override init() {
        super.init()
        loadSettings()
        applyAllSettings()
        startBluetoothScan()
    }

    // MARK: - Apply DSP to engine nodes

    func applyAllSettings() {
        applyMainEQ()
        applyHeadphoneEQ()
        applyCrossfeed()
        applyVolumeLeveling()
        applyBalance()
        applyHeadroom()
    }

    func applyMainEQ() {
        applyEQBands(mainEQBands, bypassed: isPureModeEnabled || mainEQBypassed, to: audioManager.mainEQNode)
        scheduleSettingsSave()
    }

    func applyHeadphoneEQ() {
        let bypassed = isPureModeEnabled || headphoneEQBypassed
        applyEQBands(headphoneEQBands, bypassed: bypassed, to: audioManager.headphoneEQNode)
        // AUDIT-FIX #14 — set node-level bypass so the EQ unit is fully removed
        // from the signal path (zero CPU) rather than just zeroing all band gains.
        audioManager.headphoneEQNode.auAudioUnit.shouldBypassEffect = bypassed
        scheduleSettingsSave()
    }

    private func applyEQBands(_ bands: [OrpheusEQBand], bypassed: Bool, to node: AVAudioUnitEQ) {
        let nodeBands = node.bands
        for i in 0..<nodeBands.count {
            if i < bands.count {
                let b = bands[i]
                nodeBands[i].filterType = b.filterType.avType
                nodeBands[i].frequency  = b.frequency
                nodeBands[i].gain       = bypassed ? 0 : b.gain
                nodeBands[i].bandwidth  = b.bandwidth
                nodeBands[i].bypass     = bypassed || !b.isActive
            } else {
                nodeBands[i].bypass = true
                nodeBands[i].gain   = 0
            }
        }
    }

    /// Apply a CrossfeedPreset from the PlaybackProfileManager without touching the
    /// user's permanent bypass preference. Preset parameters (strength/frequency/delay)
    /// are written to the DSP engine and take effect immediately.
    func applyCrossfeedPreset(_ preset: CrossfeedPreset) {
        crossfeedLevel     = preset.strength
        crossfeedFrequency = preset.cutoffHz
        crossfeedDelay     = preset.delayMs
        applyCrossfeed()
    }

    func applyCrossfeed() {
        // profileDrivenCrossfeedBypassed is set by PlaybackProfileManager based on the
        // resolved profile — it does not modify the user's crossfeedBypassed preference.
        let effectiveBypassed = isPureModeEnabled || crossfeedBypassed || profileDrivenCrossfeedBypassed || !isHeadphoneOutput

        if let au = audioManager.crossfeedAU {
            // Real Bauer DSP via custom AUAudioUnit
            au.isBypassed   = effectiveBypassed
            au.strength     = crossfeedLevel
            au.cutoffHz     = crossfeedFrequency
            au.delayMs      = crossfeedDelay
        } else {
            // Fallback: pass-through mixer until the AU finishes loading
            audioManager.crossfeedMixer.outputVolume = 1.0
        }
        scheduleSettingsSave()
    }

    func applyVolumeLeveling() {
        let mixer = audioManager.levelingMixer
        if isPureModeEnabled || volumeLevelingBypassed {
            mixer.outputVolume = 1.0
        } else {
            let gainDB = volumeLevelingTargetLUFS - (-14.0)
            mixer.outputVolume = min(1.0, max(0.01, pow(10.0, gainDB / 20.0)))
        }
        scheduleSettingsSave()
    }

    func applyBalance() {
        let mixer = audioManager.balanceMixer
        if isPureModeEnabled || balanceBypassed {
            mixer.pan = 0
            mixer.outputVolume = 1.0
        } else {
            let pan = (balanceRight - balanceLeft) / 12.0
            mixer.pan          = max(-1.0, min(1.0, pan))
            mixer.outputVolume = 1.0
        }
        scheduleSettingsSave()
    }

    func applyHeadroom() {
        let mainMixer = audioManager.engine.mainMixerNode
        if isPureModeEnabled || headroomBypassed {
            mainMixer.outputVolume = 1.0
        } else {
            let db: Float = headroomMode == .auto ? -3.0 : max(-3.0, min(0.0, headroomManualDB))
            mainMixer.outputVolume = pow(10.0, db / 20.0)
        }
        scheduleSettingsSave()
    }

    // MARK: - Signal-path reporting

    func signalPathState(isPlaybackRoutedThroughOrpheus: Bool) -> OrpheusSignalPathState {
        var items: [OrpheusSignalPathItem] = []
        let presetName = activePresetID.flatMap { id in presets.first(where: { $0.id == id })?.name }

        let activeMainBands = mainEQBands.filter { $0.isActive && abs($0.gain) > 0.05 }
        if !mainEQBypassed && !activeMainBands.isEmpty {
            items.append(OrpheusSignalPathItem(
                title: "EQ",
                technicalValue: "\(activeMainBands.count) active band(s)",
                explanation: "Parametric EQ changes frequency balance according to the configured Orpheus bands."
            ))
        }

        let activeHeadphoneBands = headphoneEQBands.filter { $0.isActive && abs($0.gain) > 0.05 }
        if !headphoneEQBypassed && !activeHeadphoneBands.isEmpty {
            items.append(OrpheusSignalPathItem(
                title: "Headphone EQ",
                technicalValue: "\(activeHeadphoneBands.count) active band(s)",
                explanation: "Headphone EQ applies a device/preset-specific frequency correction."
            ))
        }

        if !crossfeedBypassed && crossfeedLevel > 0.01 && isHeadphoneOutput {
            items.append(OrpheusSignalPathItem(
                title: "Crossfeed",
                technicalValue: String(format: "%.0f%% strength · %.0f Hz · %.1f ms",
                                       crossfeedLevel * 100, crossfeedFrequency, crossfeedDelay),
                explanation: "Bauer crossfeed reduces stereo width on headphones, softening hard-panned content and reducing listening fatigue."
            ))
        }

        if !volumeLevelingBypassed {
            items.append(OrpheusSignalPathItem(
                title: "Volume leveling",
                technicalValue: "\(volumeLevelingMode.rawValue) · target \(String(format: "%.0f", volumeLevelingTargetLUFS)) LUFS",
                explanation: "Volume leveling is configured to make perceived loudness more consistent between tracks."
            ))
        }

        if !headroomBypassed {
            let db = headroomMode == .auto ? -3.0 : max(-3.0, min(0.0, headroomManualDB))
            if db < -0.05 {
                items.append(OrpheusSignalPathItem(
                    title: "Headroom",
                    technicalValue: String(format: "%.1f dB", db),
                    explanation: "Headroom lowers level before processing to reduce clipping risk when boosts or leveling are used."
                ))
            }
        }

        if !balanceBypassed && (abs(balanceLeft) > 0.05 || abs(balanceRight) > 0.05 || balanceMono) {
            let mode = balanceMono ? "mono" : String(format: "L %.1f dB / R %.1f dB", balanceLeft, balanceRight)
            items.append(OrpheusSignalPathItem(
                title: "Balance",
                technicalValue: mode,
                explanation: "Balance/mono changes channel presentation according to Orpheus settings."
            ))
        }

        if srcMode != .never {
            items.append(OrpheusSignalPathItem(
                title: "Sample-rate conversion preference",
                technicalValue: srcMode.rawValue,
                explanation: "An SRC preference is configured. Hyperion does not verify actual sample-rate conversion unless playback is routed through a reporting processor."
            ))
        }

        let inactive = [
            mainEQBypassed || activeMainBands.isEmpty ? "EQ" : nil,
            headphoneEQBypassed || activeHeadphoneBands.isEmpty ? "Headphone EQ" : nil,
            crossfeedBypassed || crossfeedLevel <= 0.01 || !isHeadphoneOutput ? "Crossfeed" : nil,
            volumeLevelingBypassed ? "Volume leveling" : nil,
            headroomBypassed ? "Headroom" : nil,
            balanceBypassed || (abs(balanceLeft) <= 0.05 && abs(balanceRight) <= 0.05 && !balanceMono) ? "Balance" : nil
        ].compactMap { $0 }

        // In Pure Mode all processing is bypassed on the graph, so nothing is "active"
        // even if Orpheus is routing. The items are still captured for reference.
        let orpheusRoutedAndNormal = isPlaybackRoutedThroughOrpheus && !isPureModeEnabled
        return OrpheusSignalPathState(
            isPlaybackRoutedThroughOrpheus: isPlaybackRoutedThroughOrpheus,
            isPureModeEnabled: isPureModeEnabled,
            activePresetName: presetName,
            activeItems: orpheusRoutedAndNormal ? items : [],
            configuredOnlyItems: orpheusRoutedAndNormal ? [] : (isPlaybackRoutedThroughOrpheus ? [] : items),
            inactiveItems: inactive
        )
    }

    // MARK: - Presets

    func saveCurrentAsPreset(name: String, deviceName: String? = nil) {
        let preset = currentSnapshot(name: name, deviceName: deviceName)
        presets.append(preset)
        activePresetID = preset.id
        saveSettingsNow()
    }

    func loadPreset(_ preset: OrpheusPreset) {
        mainEQBands              = preset.mainEQBands
        mainEQBypassed           = preset.mainEQBypassed
        headphoneEQBands         = preset.headphoneEQBands
        headphoneEQBypassed      = preset.headphoneEQBypassed
        crossfeedFrequency       = preset.crossfeedFrequency
        crossfeedLevel           = preset.crossfeedLevel
        crossfeedDelay           = preset.crossfeedDelay
        crossfeedBypassed        = preset.crossfeedBypassed
        volumeLevelingMode       = preset.volumeLevelingMode
        volumeLevelingTargetLUFS = preset.volumeLevelingTargetLUFS
        volumeLevelingBypassed   = preset.volumeLevelingBypassed
        balanceLeft              = preset.balanceLeft
        balanceRight             = preset.balanceRight
        balanceMono              = preset.balanceMono
        balanceBypassed          = preset.balanceBypassed
        srcMode                  = preset.srcMode
        headroomMode             = preset.headroomMode
        headroomManualDB         = preset.headroomManualDB
        headroomBypassed         = preset.headroomBypassed
        activePresetID           = preset.id
        applyAllSettings()
    }

    func deletePreset(_ preset: OrpheusPreset) {
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        saveSettingsNow()
    }

    func updatePreset(_ preset: OrpheusPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        saveSettingsNow()
    }

    private func currentSnapshot(name: String, deviceName: String?) -> OrpheusPreset {
        OrpheusPreset(
            name:                    name,
            deviceName:              deviceName,
            mainEQBands:             mainEQBands,
            mainEQBypassed:          mainEQBypassed,
            headphoneEQBands:        headphoneEQBands,
            headphoneEQBypassed:     headphoneEQBypassed,
            crossfeedFrequency:      crossfeedFrequency,
            crossfeedLevel:          crossfeedLevel,
            crossfeedDelay:          crossfeedDelay,
            crossfeedBypassed:       crossfeedBypassed,
            volumeLevelingMode:      volumeLevelingMode,
            volumeLevelingTargetLUFS: volumeLevelingTargetLUFS,
            volumeLevelingBypassed:  volumeLevelingBypassed,
            balanceLeft:             balanceLeft,
            balanceRight:            balanceRight,
            balanceMono:             balanceMono,
            balanceBypassed:         balanceBypassed,
            srcMode:                 srcMode,
            headroomMode:            headroomMode,
            headroomManualDB:        headroomManualDB,
            headroomBypassed:        headroomBypassed
        )
    }

    // MARK: - Persistence

    private static let defaultsKey = "OrpheusDSPSettings_v1"

    private struct Stored: Codable {
        var mainEQBands:             [OrpheusEQBand]
        var mainEQBypassed:          Bool
        var headphoneEQBands:        [OrpheusEQBand]
        var headphoneEQBypassed:     Bool
        var crossfeedFrequency:      Float
        var crossfeedLevel:          Float
        var crossfeedDelay:          Float?  // optional for backward compat with old saves
        var crossfeedBypassed:       Bool
        var volumeLevelingMode:      VolumeLevelingMode
        var volumeLevelingTargetLUFS: Float
        var volumeLevelingBypassed:  Bool
        var balanceLeft:             Float
        var balanceRight:            Float
        var balanceMono:             Bool
        var balanceBypassed:         Bool
        var srcMode:                 SRCMode
        var headroomMode:            HeadroomMode
        var headroomManualDB:        Float
        var headroomBypassed:        Bool
        var presets:                 [OrpheusPreset]
        var activePresetID:          UUID?
    }

    func scheduleSettingsSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSettingsNow()
        }
    }

    func saveSettingsNow() {
        let s = Stored(
            mainEQBands:             mainEQBands,
            mainEQBypassed:          mainEQBypassed,
            headphoneEQBands:        headphoneEQBands,
            headphoneEQBypassed:     headphoneEQBypassed,
            crossfeedFrequency:      crossfeedFrequency,
            crossfeedLevel:          crossfeedLevel,
            crossfeedDelay:          crossfeedDelay,
            crossfeedBypassed:       crossfeedBypassed,
            volumeLevelingMode:      volumeLevelingMode,
            volumeLevelingTargetLUFS: volumeLevelingTargetLUFS,
            volumeLevelingBypassed:  volumeLevelingBypassed,
            balanceLeft:             balanceLeft,
            balanceRight:            balanceRight,
            balanceMono:             balanceMono,
            balanceBypassed:         balanceBypassed,
            srcMode:                 srcMode,
            headroomMode:            headroomMode,
            headroomManualDB:        headroomManualDB,
            headroomBypassed:        headroomBypassed,
            presets:                 presets,
            activePresetID:          activePresetID
        )
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let s    = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        mainEQBands              = s.mainEQBands
        mainEQBypassed           = s.mainEQBypassed
        headphoneEQBands         = s.headphoneEQBands
        headphoneEQBypassed      = s.headphoneEQBypassed
        crossfeedFrequency       = s.crossfeedFrequency
        crossfeedLevel           = s.crossfeedLevel
        crossfeedDelay           = s.crossfeedDelay ?? 0.3
        crossfeedBypassed        = s.crossfeedBypassed
        volumeLevelingMode       = s.volumeLevelingMode
        volumeLevelingTargetLUFS = s.volumeLevelingTargetLUFS
        volumeLevelingBypassed   = s.volumeLevelingBypassed
        balanceLeft              = s.balanceLeft
        balanceRight             = s.balanceRight
        balanceMono              = s.balanceMono
        balanceBypassed          = s.balanceBypassed
        srcMode                  = s.srcMode
        headroomMode             = s.headroomMode
        headroomManualDB         = s.headroomManualDB
        headroomBypassed         = s.headroomBypassed
        presets                  = s.presets
        activePresetID           = s.activePresetID
    }

    // MARK: - Default EQ bands

    static func defaultEQBands() -> [OrpheusEQBand] {
        let freqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        return freqs.map { OrpheusEQBand(filterType: .peak, frequency: $0, gain: 0, bandwidth: 1, isActive: true) }
    }

    // MARK: - EQ frequency response helper (for Canvas drawing)

    /// Returns the summed dB gain at `freq` Hz from all active bands in `bands`.
    nonisolated static func responseDB(at freq: Double, bands: [OrpheusEQBand], bypassed: Bool) -> Double {
        guard !bypassed else { return 0 }
        var total: Double = 0
        for band in bands where band.isActive {
            total += bandGainDB(at: freq, band: band)
        }
        return max(-30, min(30, total))
    }

    nonisolated private static func bandGainDB(at freq: Double, band: OrpheusEQBand) -> Double {
        let f0    = Double(band.frequency)
        let g     = Double(band.gain)
        let q     = max(0.1, Double(band.bandwidth))
        guard f0 > 0, g != 0 else { return 0 }

        switch band.filterType {
        case .peak:
            let ratio = freq / f0
            let d = 1.0 + pow((ratio - 1.0 / ratio) * q, 2)
            return g / d

        case .lowShelf:
            let shelving = 1.0 - 1.0 / (1.0 + pow(freq / f0, 2.0 * q))
            return g * shelving

        case .highShelf:
            let shelving = 1.0 / (1.0 + pow(f0 / freq, 2.0 * q))
            return g * shelving

        case .lowPass:
            return freq < f0 ? 0 : g * max(0, 1.0 - (freq - f0) / f0)

        case .highPass:
            return freq > f0 ? 0 : g * max(0, 1.0 - (f0 - freq) / f0)
        }
    }

    // MARK: - Bluetooth / route-change auto-switch

    /// Preset ID that was active before a Bluetooth auto-switch; restored on disconnect.
    private var preAutoSwitchPresetID: UUID? = nil

    private func startBluetoothScan() {
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteDidChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        // Seed headphone state from the current route at launch.
        let headphoneTypes: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE
        ]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        isHeadphoneOutput = outputs.contains { headphoneTypes.contains($0.portType) }
    }

    @objc private nonisolated func audioRouteDidChange(_ note: Notification) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs

        let headphoneTypes: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE
        ]
        let headphonesConnected = outputs.contains { headphoneTypes.contains($0.portType) }

        let btName = outputs.first(where: {
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP  ||
            $0.portType == .bluetoothLE
        })?.portName

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Update headphone state and re-apply crossfeed bypass accordingly.
            self.isHeadphoneOutput = headphonesConnected
            self.applyCrossfeed()

            // Bluetooth preset auto-switch
            if let name = btName, !name.isEmpty {
                if self.connectedBluetoothDeviceName != name {
                    self.connectedBluetoothDeviceName = name
                    self.autoSwitchPresetIfNeeded(for: name)
                }
            } else {
                self.restorePreAutoSwitchPreset()
                self.connectedBluetoothDeviceName = nil
            }
        }
    }

    func autoSwitchPresetIfNeeded(for deviceName: String) {
        guard let match = presets.first(where: {
            guard let pdn = $0.deviceName, !pdn.isEmpty else { return false }
            return deviceName.lowercased().contains(pdn.lowercased()) ||
                   pdn.lowercased().contains(deviceName.lowercased())
        }) else { return }
        // Save the current preset ID so we can restore it on disconnect.
        preAutoSwitchPresetID = activePresetID
        loadPreset(match)
        ServerLogStore.shared.info("Orpheus: auto-switched to preset \"\(match.name)\" for \"\(deviceName)\"")
    }

    private func restorePreAutoSwitchPreset() {
        guard let restoreID = preAutoSwitchPresetID,
              let preset = presets.first(where: { $0.id == restoreID }) else {
            preAutoSwitchPresetID = nil
            return
        }
        preAutoSwitchPresetID = nil
        loadPreset(preset)
        ServerLogStore.shared.info("Orpheus: restored preset \"\(preset.name)\" after Bluetooth disconnect")
    }

    /// Assign the device-name substring for an existing preset (used from Headphone Profiles UI).
    func setDeviceName(_ name: String?, for presetID: UUID) {
        guard let idx = presets.firstIndex(where: { $0.id == presetID }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        presets[idx].deviceName = trimmed.isEmpty ? nil : trimmed
        saveSettingsNow()
    }
}

// MARK: - CBCentralManagerDelegate

extension OrpheusDSPEngine: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // No-op; we only use retrieveConnectedPeripherals which works in any state.
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let name = peripheral.name ?? ""
        guard !name.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.connectedBluetoothDeviceName = name
            self?.autoSwitchPresetIfNeeded(for: name)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.restorePreAutoSwitchPreset()
            self?.connectedBluetoothDeviceName = nil
        }
    }
}
