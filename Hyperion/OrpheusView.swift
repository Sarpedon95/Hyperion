import SwiftUI
import AVFoundation
import CoreBluetooth

// MARK: - Main Orpheus View

struct OrpheusView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared
    @State private var showingPresetSheet = false
    @State private var newPresetName = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    orpheusHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    pureModeToggle
                        .padding(.bottom, 20)

                    presetsRow
                        .padding(.bottom, 24)

                    LazyVGrid(columns: columns, spacing: 14) {
                        mainEQCard
                        headphoneEQCard
                        crossfeedCard
                        volumeLevelingCard
                        balanceCard
                        srcCard
                        headroomCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .opacity(dsp.isPureModeEnabled ? 0.5 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: dsp.isPureModeEnabled)
                }
            }
            .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        NavigationLink {
                            OrpheusEngineDebugView()
                        } label: {
                            Image(systemName: "chart.bar.doc.horizontal")
                                .foregroundColor(.roonSecondary)
                        }
                        NavigationLink {
                            OrpheusSignalPathView()
                        } label: {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundColor(.roonSecondary)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPresetSheet) {
                savePresetSheet
            }
        }
    }

    // MARK: - Header

    private var orpheusHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ORPHEUS")
                .font(.roonTitle(34, weight: .bold))
                .foregroundColor(.roonPrimary)
            Text("Precision Audio Control")
                .font(.roonBody(14))
                .foregroundColor(.roonSecondary)
        }
    }

    // MARK: - Pure Mode toggle

    private var pureModeToggle: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(dsp.isPureModeEnabled ? Color.roonAccent.opacity(0.15) : Color.roonSurface)
                    .frame(width: 40, height: 40)
                Image(systemName: "waveform.path")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(dsp.isPureModeEnabled ? .roonAccent : .roonTertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Pure Mode")
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                Text(dsp.isPureModeEnabled
                     ? "EQ, crossfeed, leveling, and all processing bypassed."
                     : "Bypasses EQ, crossfeed, leveling, balance, and all sound-shaping processing.")
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { dsp.isPureModeEnabled },
                set: {
                    dsp.isPureModeEnabled = $0
                    dsp.applyAllSettings()
                    Haptics.light()
                }
            ))
            .labelsHidden()
            .tint(.roonAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(dsp.isPureModeEnabled ? Color.roonAccent.opacity(0.07) : Color.roonElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(dsp.isPureModeEnabled ? Color.roonAccent.opacity(0.45) : Color.roonBorder, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: dsp.isPureModeEnabled)
    }

    // MARK: - Presets row

    private var presetsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PRESETS")
                    .font(.roonBody(11, weight: .semibold))
                    .foregroundColor(.roonAccent)
                    .kerning(1.2)
                Spacer()
                Button {
                    newPresetName = ""
                    showingPresetSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Save")
                    }
                    .font(.roonBody(12, weight: .semibold))
                    .foregroundColor(.roonAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if dsp.presets.isEmpty {
                Text("No presets yet — tap Save to create one")
                    .font(.roonBody(12))
                    .foregroundColor(.roonTertiary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(dsp.presets) { preset in
                            OrpheusPresetChip(
                                preset: preset,
                                isActive: dsp.activePresetID == preset.id,
                                onTap: { dsp.loadPreset(preset) },
                                onDelete: { dsp.deletePreset(preset) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - DSP module cards

    private var mainEQCard: some View {
        let summary = dsp.mainEQBands.filter { $0.isActive && $0.gain != 0 }
            .prefix(2)
            .map { b in String(format: "%.0fHz %+.0fdB", b.frequency, b.gain) }
            .joined(separator: "  ")

        return OrpheusDSPCard(
            title: "Parametric EQ",
            subtitle: summary.isEmpty ? "Flat" : summary,
            iconName: "slider.horizontal.3",
            isEnabled: Binding(
                get: { !dsp.mainEQBypassed },
                set: { dsp.mainEQBypassed = !$0; dsp.applyMainEQ() }
            ),
            accent: .roonAccent
        ) {
            OrpheusEQDetailView(isHeadphone: false)
        }
    }

    private var headphoneEQCard: some View {
        let summary = dsp.headphoneEQBands.filter { $0.isActive && $0.gain != 0 }
            .prefix(2)
            .map { b in String(format: "%.0fHz %+.0fdB", b.frequency, b.gain) }
            .joined(separator: "  ")

        return OrpheusDSPCard(
            title: "Headphone EQ",
            subtitle: summary.isEmpty ? "Flat" : summary,
            iconName: "headphones",
            isEnabled: Binding(
                get: { !dsp.headphoneEQBypassed },
                set: { dsp.headphoneEQBypassed = !$0; dsp.applyHeadphoneEQ() }
            ),
            accent: Color(hex: "#7b6cf6")
        ) {
            OrpheusEQDetailView(isHeadphone: true)
        }
    }

    private var crossfeedCard: some View {
        OrpheusDSPCard(
            title: "Crossfeed",
            subtitle: String(format: "%.0f Hz · %+.0f dB", dsp.crossfeedFrequency, dsp.crossfeedLevel),
            iconName: "arrow.left.arrow.right",
            isEnabled: Binding(
                get: { !dsp.crossfeedBypassed },
                set: { dsp.crossfeedBypassed = !$0; dsp.applyCrossfeed() }
            ),
            accent: Color(hex: "#5ba3c9")
        ) {
            OrpheusCrossfeedView()
        }
    }

    private var volumeLevelingCard: some View {
        OrpheusDSPCard(
            title: "Volume Leveling",
            subtitle: "\(dsp.volumeLevelingMode.rawValue) · \(Int(dsp.volumeLevelingTargetLUFS)) LUFS",
            iconName: "waveform.path.ecg",
            isEnabled: Binding(
                get: { !dsp.volumeLevelingBypassed },
                set: { dsp.volumeLevelingBypassed = !$0; dsp.applyVolumeLeveling() }
            ),
            accent: Color(hex: "#e89b3f")
        ) {
            OrpheusVolumeLevelingView()
        }
    }

    private var balanceCard: some View {
        let lStr = dsp.balanceLeft  == 0 ? "0" : String(format: "%+.1f", -dsp.balanceLeft)
        let rStr = dsp.balanceRight == 0 ? "0" : String(format: "%+.1f",  dsp.balanceRight)
        return OrpheusDSPCard(
            title: "Balance",
            subtitle: "L \(lStr) dB · R \(rStr) dB\(dsp.balanceMono ? " · Mono" : "")",
            iconName: "dial.medium",
            isEnabled: Binding(
                get: { !dsp.balanceBypassed },
                set: { dsp.balanceBypassed = !$0; dsp.applyBalance() }
            ),
            accent: Color(hex: "#c96b8a")
        ) {
            OrpheusBalanceView()
        }
    }

    private var srcCard: some View {
        let session = AVAudioSession.sharedInstance()
        let rate = Int(session.sampleRate)
        return OrpheusDSPCard(
            title: "Sample Rate",
            subtitle: "\(dsp.srcMode.rawValue)\n\(rate > 0 ? "\(rate) Hz" : "—")",
            iconName: "waveform",
            isEnabled: .constant(true),
            accent: Color(hex: "#5b9c8a")
        ) {
            OrpheusSRCView()
        }
    }

    private var headroomCard: some View {
        let dbStr: String
        switch dsp.headroomMode {
        case .auto:   dbStr = "−3 dB (auto)"
        case .manual: dbStr = String(format: "%.1f dB", dsp.headroomManualDB)
        }
        return OrpheusDSPCard(
            title: "Headroom",
            subtitle: dbStr,
            iconName: "speaker.wave.3",
            isEnabled: Binding(
                get: { !dsp.headroomBypassed },
                set: { dsp.headroomBypassed = !$0; dsp.applyHeadroom() }
            ),
            accent: Color(hex: "#a0a860")
        ) {
            OrpheusHeadroomView()
        }
    }

    // MARK: - Save preset sheet

    private var savePresetSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Preset name", text: $newPresetName)
                        .autocorrectionDisabled()
                }
                if dsp.connectedBluetoothDeviceName != nil {
                    Section("Auto-switch") {
                        Text("This preset will auto-load when \"\(dsp.connectedBluetoothDeviceName ?? "")\" connects.")
                            .font(.roonBody(13))
                            .foregroundColor(.roonSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Save Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPresetSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        dsp.saveCurrentAsPreset(name: name, deviceName: dsp.connectedBluetoothDeviceName)
                        showingPresetSheet = false
                    }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - DSP Card

struct OrpheusDSPCard<Destination: View>: View {
    let title: String
    let subtitle: String
    let iconName: String
    @Binding var isEnabled: Bool
    let accent: Color
    @ViewBuilder let destination: () -> Destination

    @State private var navigate = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Thematic background illustration
            Image(systemName: iconName)
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundColor(accent.opacity(0.12))
                .offset(x: 8, y: 8)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.roonBody(13, weight: .bold))
                    .foregroundColor(.roonPrimary)
                    .padding(.bottom, 5)

                Text(subtitle)
                    .font(.roonBody(11))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                HStack {
                    Circle()
                        .fill(isEnabled ? accent : Color.roonTertiary)
                        .frame(width: 6, height: 6)
                    Text(isEnabled ? "On" : "Bypass")
                        .font(.roonBody(10))
                        .foregroundColor(isEnabled ? accent : .roonTertiary)
                    Spacer()
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .tint(accent)
                        .scaleEffect(0.8)
                }
            }
            .padding(12)
        }
        .frame(height: 120)
        .background(Color.roonElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isEnabled ? accent.opacity(0.3) : Color.roonBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { navigate = true }
        .navigationDestination(isPresented: $navigate) { destination() }
    }
}

// MARK: - Preset chip

struct OrpheusPresetChip: View {
    let preset: OrpheusPreset
    let isActive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let dev = preset.deviceName, !dev.isEmpty {
                Image(systemName: "headphones")
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? Color.roonBase : .roonSecondary)
            }
            Text(preset.name)
                .font(.roonBody(13, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? Color.roonBase : .roonPrimary)
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isActive ? Color.roonBase.opacity(0.7) : .roonTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive ? Color.roonAccent : Color.roonElevated)
        .clipShape(Capsule())
        .onTapGesture { onTap() }
    }
}
