import SwiftUI
import AVFoundation

struct OrpheusSignalPathView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared

    private var nodes: [SignalNode] {
        [
            SignalNode(
                label: "Source",
                detail: "LMS Stream",
                icon: "network",
                bypassed: false
            ),
            SignalNode(
                label: "EQ",
                detail: eqSummary(dsp.mainEQBands, bypassed: dsp.mainEQBypassed),
                icon: "slider.horizontal.3",
                bypassed: dsp.mainEQBypassed
            ),
            SignalNode(
                label: "HP EQ",
                detail: eqSummary(dsp.headphoneEQBands, bypassed: dsp.headphoneEQBypassed),
                icon: "headphones",
                bypassed: dsp.headphoneEQBypassed
            ),
            SignalNode(
                label: "Crossfeed",
                detail: dsp.crossfeedBypassed ? "Off" : String(format: "%.0fHz", dsp.crossfeedFrequency),
                icon: "arrow.left.arrow.right",
                bypassed: dsp.crossfeedBypassed
            ),
            SignalNode(
                label: "Leveling",
                detail: dsp.volumeLevelingBypassed ? "Off" : "\(Int(dsp.volumeLevelingTargetLUFS)) LUFS",
                icon: "waveform.path.ecg",
                bypassed: dsp.volumeLevelingBypassed
            ),
            SignalNode(
                label: "Output",
                detail: currentOutputName(),
                icon: "speaker.wave.2",
                bypassed: false
            )
        ]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { idx, node in
                    HStack(spacing: 0) {
                        SignalNodePill(node: node)
                        if idx < nodes.count - 1 {
                            SignalConnector()
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Color.roonBase)
        .navigationTitle("Signal Path")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .background(Color.roonBase.ignoresSafeArea())
    }

    private func eqSummary(_ bands: [OrpheusEQBand], bypassed: Bool) -> String {
        if bypassed { return "Off" }
        let active = bands.filter { $0.isActive && $0.gain != 0 }.count
        return active == 0 ? "Flat" : "\(active) band\(active == 1 ? "" : "s")"
    }

    private func currentOutputName() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.first?.portName ?? "Unknown"
    }
}

private struct SignalNode {
    let label: String
    let detail: String
    let icon: String
    let bypassed: Bool
}

private struct SignalNodePill: View {
    let node: SignalNode

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: node.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(node.bypassed ? .roonTertiary : .roonAccent)

            Text(node.label)
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(node.bypassed ? .roonTertiary : .roonPrimary)

            Text(node.detail)
                .font(.roonBody(10))
                .foregroundColor(.roonTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 70)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(node.bypassed ? Color.roonSurface : Color.roonElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(node.bypassed ? Color.roonBorder : Color.roonAccent.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct SignalConnector: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.roonBorder)
                .frame(width: 16, height: 1.5)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(.roonTertiary)
            Rectangle()
                .fill(Color.roonBorder)
                .frame(width: 4, height: 1.5)
        }
    }
}

