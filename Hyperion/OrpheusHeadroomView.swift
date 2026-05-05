import SwiftUI

struct OrpheusHeadroomView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared

    var body: some View {
        List {
            Section {
                Toggle("Bypass", isOn: Binding(
                    get: { dsp.headroomBypassed },
                    set: { dsp.headroomBypassed = $0; dsp.applyHeadroom() }
                ))
                .tint(.roonAccent)
            }

            Section("Mode") {
                Picker("Mode", selection: Binding(
                    get: { dsp.headroomMode },
                    set: { dsp.headroomMode = $0; dsp.applyHeadroom() }
                )) {
                    ForEach(HeadroomMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if dsp.headroomMode == .manual {
                Section("Manual Headroom") {
                    LabeledSlider(
                        label: "Headroom",
                        value: Binding(
                            get: { Double(dsp.headroomManualDB) },
                            set: { dsp.headroomManualDB = Float($0); dsp.applyHeadroom() }
                        ),
                        range: -3...0,
                        format: "%.1f dB"
                    )
                }
            }

            Section {
                HStack {
                    Text("Applied headroom")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    let db = dsp.headroomBypassed ? 0.0 :
                        (dsp.headroomMode == .auto ? -3.0 : Double(dsp.headroomManualDB))
                    Text(String(format: "%.1f dB", db))
                        .font(.roonMono(13))
                        .foregroundColor(.roonPrimary)
                }
            }

            Section("About") {
                Text("Headroom Management ensures the output level doesn't clip after EQ or other processing adds gain. −3 dB (Auto) is a conservative default that protects against inter-sample peaks.")
                    .font(.roonBody(12))
                    .foregroundColor(.roonTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Headroom Management")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
