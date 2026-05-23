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

            // AUDIT-FIX #19 — the gain applied is a fixed offset (dB), not a
            // measured LUFS value. Relabelled to avoid misleading audiophile users.
            Section("Offset") {
                LabeledSlider(
                    label: "Volume Offset (dB)",
                    value: Binding(
                        get: { Double(dsp.volumeLevelingTargetLUFS) },
                        set: { dsp.volumeLevelingTargetLUFS = Float($0); dsp.applyVolumeLeveling() }
                    ),
                    range: -23 ... -9,
                    format: "%.0f dB"
                )

                HStack {
                    Text("Current offset")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    Text(String(format: "%.0f dB", dsp.volumeLevelingTargetLUFS))
                        .font(.roonMono(13))
                        .foregroundColor(.roonPrimary)
                }
            }

            Section("Reference offsets") {
                LevelReferenceRow(label: "Streaming (Spotify, Apple Music)", db: -14)
                LevelReferenceRow(label: "Broadcast standard (EBU R128)", db: -23)
                LevelReferenceRow(label: "CD/audiophile", db: -9)
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Volume Offset")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct LevelReferenceRow: View {
    let label: String
    let db: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.roonBody(12))
                .foregroundColor(.roonSecondary)
            Spacer()
            Text("\(db) dB")
                .font(.roonMono(12))
                .foregroundColor(.roonTertiary)
        }
    }
}
