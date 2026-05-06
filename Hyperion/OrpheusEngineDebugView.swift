import SwiftUI
import AVFoundation

// MARK: - Orpheus Engine Diagnostics

/// Full-fidelity diagnostics panel for the Orpheus playback engine.
/// Shows engine routing, stream classification, format info, DSP state,
/// and fallback reason. Accessible from OrpheusView toolbar.
struct OrpheusEngineDebugView: View {

    @ObservedObject private var player = PlayerViewModel.shared
    @ObservedObject private var dsp    = OrpheusDSPEngine.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                engineSection
                streamSection
                formatSection
                bufferingSection
                dspSection
                if player.orpheusFallbackReason != nil || player.error != nil {
                    errorSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Engine Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Engine routing

    private var engineSection: some View {
        DiagSection(title: "ENGINE") {
            DiagRow(
                label: "Active engine",
                value: engineLabel,
                accent: player.isPlaybackRoutedThroughOrpheus ? .green : .roonSecondary
            )
            DiagRow(
                label: "isPlaybackRoutedThroughOrpheus",
                value: boolLabel(player.isPlaybackRoutedThroughOrpheus),
                accent: player.isPlaybackRoutedThroughOrpheus ? .green : .roonTertiary
            )
            DiagRow(
                label: "didStartAudiblePlayback",
                value: boolLabel(player.orpheusDidStartAudiblePlayback),
                accent: player.orpheusDidStartAudiblePlayback ? .green : .roonTertiary
            )
            DiagRow(
                label: "useOrpheusEngine (pref)",
                value: boolLabel(player.useOrpheusEngine)
            )
        }
    }

    private var engineLabel: String {
        if player.isPlaybackRoutedThroughOrpheus { return "Orpheus (PCM → DSP chain)" }
        if player.useOrpheusEngine               { return "Loading / Compatibility fallback" }
        return "Compatibility (AVPlayer)"
    }

    // MARK: - Stream info

    private var streamSection: some View {
        DiagSection(title: "STREAM") {
            DiagRow(label: "Source URL",
                    value: player.currentStreamURL.map {
                        let s = $0.absoluteString
                        return s.count > 60 ? "…" + s.suffix(57) : s
                    } ?? "—")
            DiagRow(
                label: "streamKind",
                value: player.orpheusStreamKind.description,
                accent: player.orpheusStreamKind == .streamLike ? .yellow : .roonSecondary
            )
            DiagRow(
                label: "playbackMode",
                value: player.orpheusPlaybackMode.description,
                accent: player.orpheusPlaybackMode == .streaming ? .yellow : .green
            )
            DiagRow(label: "durationKnown",
                    value: boolLabel(player.orpheusDurationKnown),
                    accent: player.orpheusDurationKnown ? .green : .roonTertiary)
            DiagRow(label: "canSeek",
                    value: boolLabel(player.orpheusCanSeek),
                    accent: player.orpheusCanSeek ? .green : .yellow)
            if player.duration > 0 {
                DiagRow(label: "duration",
                        value: String(format: "%.2f s", player.duration))
            }
        }
    }

    // MARK: - Format

    private var formatSection: some View {
        DiagSection(title: "FORMAT") {
            DiagRow(label: "Source (LMS / track)",
                    value: player.sourceFormat.isEmpty ? "—" : player.sourceFormat)
            DiagRow(label: "Decoded (AVAssetTrack)",
                    value: player.orpheusDecodedFormat.isEmpty ? "—" : player.orpheusDecodedFormat)
            DiagRow(label: "Output route",
                    value: player.outputFormat.isEmpty ? "—" : player.outputFormat)
            if let q = player.lmsAudioQuality {
                if q.sampleRate > 0 {
                    DiagRow(label: "LMS sample rate",
                            value: "\(q.sampleRate) Hz")
                }
                if q.sampleSize > 0 {
                    DiagRow(label: "LMS bit depth",
                            value: "\(q.sampleSize)-bit")
                }
                if let br = q.bitrate, !br.isEmpty {
                    DiagRow(label: "LMS bitrate", value: br)
                }
                if let lossless = q.lossless {
                    DiagRow(label: "LMS lossless",
                            value: boolLabel(lossless),
                            accent: lossless ? .green : .roonTertiary)
                }
            }
        }
    }

    // MARK: - Buffering

    private var bufferingSection: some View {
        DiagSection(title: "BUFFERING") {
            DiagRow(
                label: "isBuffering",
                value: boolLabel(player.isLoading),
                accent: player.isLoading ? .yellow : .roonTertiary
            )
            DiagRow(
                label: "isPlaying",
                value: boolLabel(player.isPlaying),
                accent: player.isPlaying ? .green : .roonTertiary
            )
            DiagRow(
                label: "currentTime",
                value: String(format: "%.2f s", player.currentTime)
            )
        }
    }

    // MARK: - DSP state

    private var dspSection: some View {
        DiagSection(title: "DSP") {
            DiagRow(
                label: "DSP mode",
                value: dspModeLabel,
                accent: dsp.isPureModeEnabled ? .blue : .green
            )
            DiagRow(label: "Pure Mode",
                    value: boolLabel(dsp.isPureModeEnabled),
                    accent: dsp.isPureModeEnabled ? .blue : .roonTertiary)

            let state = dsp.signalPathState(isPlaybackRoutedThroughOrpheus: player.isPlaybackRoutedThroughOrpheus)
            if !state.activeItems.isEmpty {
                DiagRow(
                    label: "Active effects",
                    value: state.activeItems.map(\.title).joined(separator: ", ")
                )
            }
            if !state.inactiveItems.isEmpty {
                DiagRow(
                    label: "Bypassed / off",
                    value: state.inactiveItems.joined(separator: ", "),
                    accent: .roonTertiary
                )
            }
            if let preset = state.activePresetName {
                DiagRow(label: "Active preset", value: preset)
            }
        }
    }

    private var dspModeLabel: String {
        guard player.isPlaybackRoutedThroughOrpheus else { return "Unavailable (compatibility path)" }
        return dsp.isPureModeEnabled ? "Pure (DSP bypassed)" : "DSP active"
    }

    // MARK: - Errors / fallback

    private var errorSection: some View {
        DiagSection(title: "FALLBACK / ERROR") {
            if let reason = player.orpheusFallbackReason {
                DiagRow(label: "Fallback reason", value: reason, accent: .yellow)
            }
            if let err = player.error {
                DiagRow(label: "Last error", value: err, accent: .red)
            }
        }
    }

    // MARK: - Helpers

    private func boolLabel(_ value: Bool) -> String { value ? "true" : "false" }
}

// MARK: - Reusable sub-components

private struct DiagSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.roonTertiary)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(Color.roonSurface)
            .cornerRadius(8)
        }
    }
}

private struct DiagRow: View {
    let label: String
    let value: String
    var accent: Color = .roonSecondary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.roonTertiary)
                .frame(minWidth: 130, alignment: .leading)

            Spacer(minLength: 4)

            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(accent)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(
            Divider()
                .background(Color.roonBase.opacity(0.5)),
            alignment: .bottom
        )
    }
}

#Preview {
    NavigationStack {
        OrpheusEngineDebugView()
    }
}
