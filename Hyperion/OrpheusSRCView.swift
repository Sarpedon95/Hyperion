import SwiftUI
import AVFoundation

struct OrpheusSRCView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared

    private var sessionSampleRate: Int {
        let r = AVAudioSession.sharedInstance().sampleRate
        return r > 0 ? Int(r) : 0
    }

    private var outputChannels: Int {
        AVAudioSession.sharedInstance().outputNumberOfChannels
    }

    var body: some View {
        List {
            Section("Mode") {
                Picker("SRC Mode", selection: Binding(
                    get: { dsp.srcMode },
                    set: { dsp.srcMode = $0; dsp.scheduleSettingsSave() }
                )) {
                    ForEach(SRCMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Current Session") {
                HStack {
                    Text("Sample Rate")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    Text(sessionSampleRate > 0 ? "\(sessionSampleRate) Hz" : "—")
                        .font(.roonMono(13))
                        .foregroundColor(.roonPrimary)
                }
                HStack {
                    Text("Output Channels")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    Text("\(outputChannels)")
                        .font(.roonMono(13))
                        .foregroundColor(.roonPrimary)
                }
                HStack {
                    Text("Output Route")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    Text(currentOutputName())
                        .font(.roonBody(12))
                        .foregroundColor(.roonTertiary)
                        .lineLimit(1)
                }
            }

            Section("About") {
                Text("Sample Rate Conversion (SRC) upsamples or resamples the audio signal for compatibility with the output device. \"For Compatibility Only\" applies SRC only when the source and output rates differ.")
                    .font(.roonBody(12))
                    .foregroundColor(.roonTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Sample Rate Conversion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func currentOutputName() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .map(\.portName)
            .joined(separator: ", ")
            .nonEmptyOrDefault("—")
    }
}

private extension String {
    func nonEmptyOrDefault(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
