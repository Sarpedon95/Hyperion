import SwiftUI
import AVFoundation

struct OrpheusSignalPathView: View {

    @StateObject private var dsp    = OrpheusDSPEngine.shared
    @ObservedObject private var player = PlayerViewModel.shared

    private var nodes: [SignalNode] {
        let pure    = dsp.isPureModeEnabled
        let orpheus = player.isPlaybackRoutedThroughOrpheus
        return [
            SignalNode(label: "Source",   detail: "LMS Stream",
                       icon: "network",            bypassed: false,    pureOverride: false),
            SignalNode(label: "Engine",   detail: orpheus ? "Orpheus" : "Compat.",
                       icon: orpheus ? "waveform.path" : "play.circle",
                       bypassed: !orpheus, pureOverride: false),
            SignalNode(label: "EQ",       detail: pure ? "Pure" : eqSummary(dsp.mainEQBands, bypassed: dsp.mainEQBypassed),
                       icon: "slider.horizontal.3",
                       bypassed: pure || dsp.mainEQBypassed, pureOverride: pure && !dsp.mainEQBypassed),
            SignalNode(label: "HP EQ",    detail: pure ? "Pure" : eqSummary(dsp.headphoneEQBands, bypassed: dsp.headphoneEQBypassed),
                       icon: "headphones",
                       bypassed: pure || dsp.headphoneEQBypassed, pureOverride: pure && !dsp.headphoneEQBypassed),
            SignalNode(label: "Xfeed",    detail: (pure || dsp.crossfeedBypassed) ? (pure ? "Pure" : "Off") : String(format: "%.0f%%", dsp.crossfeedLevel * 100),
                       icon: "arrow.left.arrow.right",
                       bypassed: pure || dsp.crossfeedBypassed, pureOverride: pure && !dsp.crossfeedBypassed),
            SignalNode(label: "Leveling", detail: (pure || dsp.volumeLevelingBypassed) ? (pure ? "Pure" : "Off") : "\(Int(dsp.volumeLevelingTargetLUFS)) LUFS",
                       icon: "waveform.path.ecg",
                       bypassed: pure || dsp.volumeLevelingBypassed, pureOverride: pure && !dsp.volumeLevelingBypassed),
            SignalNode(label: "Output",   detail: currentOutputName(),
                       icon: "speaker.wave.2",     bypassed: false,    pureOverride: false)
        ]
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if dsp.isPureModeEnabled {
                    pureModeBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(nodes.enumerated()), id: \.offset) { idx, node in
                            HStack(spacing: 0) {
                                SignalNodePill(node: node)
                                if idx < nodes.count - 1 { SignalConnector() }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity)

                if !player.isPlaybackRoutedThroughOrpheus {
                    Text("Orpheus DSP is not active. Playback is using AVPlayer compatibility mode.")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(Color.roonBase)
        .navigationTitle("Signal Path")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .background(Color.roonBase.ignoresSafeArea())
    }

    private var pureModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.roonAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pure Mode is on")
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                Text("EQ and sound processing are bypassed. Saved settings are preserved.")
                    .font(.roonBody(11))
                    .foregroundColor(.roonSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.roonAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.roonAccent.opacity(0.35), lineWidth: 1)
        )
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
    let pureOverride: Bool  // bypassed by Pure Mode (not user's own bypass setting)
}

private struct SignalNodePill: View {
    let node: SignalNode

    var accentColor: Color {
        if node.pureOverride { return Color.roonAccent.opacity(0.5) }
        if node.bypassed     { return .roonTertiary }
        return .roonAccent
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: node.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accentColor)

            Text(node.label)
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(node.bypassed ? .roonTertiary : .roonPrimary)

            Text(node.detail)
                .font(.roonBody(10))
                .foregroundColor(node.pureOverride ? Color.roonAccent.opacity(0.6) : .roonTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 70)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(node.pureOverride ? Color.roonAccent.opacity(0.05) : (node.bypassed ? Color.roonSurface : Color.roonElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(node.pureOverride ? Color.roonAccent.opacity(0.25) : (node.bypassed ? Color.roonBorder : Color.roonAccent.opacity(0.35)), lineWidth: 1)
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
