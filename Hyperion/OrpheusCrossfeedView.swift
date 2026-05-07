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
                Text("Crossfeed reduces perceived stereo width on headphones, softening hard-panned content and reducing listening fatigue. Higher levels produce a narrower, more speaker-like soundstage.")
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
