import SwiftUI

struct OrpheusVolumeLevelingView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared

    var body: some View {
        List {
            Section {
                Toggle("Bypass", isOn: Binding(
                    get: { dsp.volumeLevelingBypassed },
                    set: { dsp.volumeLevelingBypassed = $0; dsp.applyVolumeLeveling() }
                ))
                .tint(.roonAccent)
            }

            Section("Mode") {
                Picker("Mode", selection: Binding(
                    get: { dsp.volumeLevelingMode },
                    set: { dsp.volumeLevelingMode = $0; dsp.applyVolumeLeveling() }
                )) {
                    ForEach(VolumeLevelingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Target Level") {
                LabeledSlider(
                    label: "Target LUFS",
                    value: Binding(
                        get: { Double(dsp.volumeLevelingTargetLUFS) },
                        set: { dsp.volumeLevelingTargetLUFS = Float($0); dsp.applyVolumeLeveling() }
                    ),
                    range: -23 ... -9,
                    format: "%.0f LUFS"
                )

                HStack {
                    Text("Current target")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    Text(String(format: "%.0f LUFS", dsp.volumeLevelingTargetLUFS))
                        .font(.roonMono(13))
                        .foregroundColor(.roonPrimary)
                }
            }

            Section("Reference levels") {
                LevelReferenceRow(label: "Streaming (Spotify, Apple Music)", lufs: -14)
                LevelReferenceRow(label: "Broadcast standard (EBU R128)", lufs: -23)
                LevelReferenceRow(label: "CD/audiophile", lufs: -9)
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Volume Leveling")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct LevelReferenceRow: View {
    let label: String
    let lufs: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.roonBody(12))
                .foregroundColor(.roonSecondary)
            Spacer()
            Text("\(lufs) LUFS")
                .font(.roonMono(12))
                .foregroundColor(.roonTertiary)
        }
    }
}
