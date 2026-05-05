import SwiftUI

struct OrpheusCrossfeedView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared

    var body: some View {
        List {
            Section {
                HStack {
                    Toggle("Bypass", isOn: Binding(
                        get: { dsp.crossfeedBypassed },
                        set: { dsp.crossfeedBypassed = $0; dsp.applyCrossfeed() }
                    ))
                    .tint(.roonAccent)
                }
            }

            Section("Settings") {
                LabeledSlider(
                    label: "Frequency",
                    value: Binding(
                        get: { Double(dsp.crossfeedFrequency) },
                        set: { dsp.crossfeedFrequency = Float($0); dsp.applyCrossfeed() }
                    ),
                    range: 200...2000,
                    format: "%.0f Hz"
                )

                LabeledSlider(
                    label: "Level",
                    value: Binding(
                        get: { Double(dsp.crossfeedLevel) },
                        set: { dsp.crossfeedLevel = Float($0); dsp.applyCrossfeed() }
                    ),
                    range: 0...12,
                    format: "%+.1f dB"
                )
            }

            Section("About") {
                Text("Crossfeed reduces the stereo width perceived through headphones by mixing a small amount of the left channel into the right and vice versa, centred around the crossfeed frequency. This simulates loudspeaker listening and reduces listening fatigue.")
                    .font(.roonBody(12))
                    .foregroundColor(.roonTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Crossfeed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
