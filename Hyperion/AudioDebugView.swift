import SwiftUI

// MARK: - Audio Debug Info Overlay

struct AudioDebugView: View {
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundColor(player.isBitPerfect ? .green : .yellow)
                    .font(.system(size: 14, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Audio Format")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.roonPrimary)

                        Text(player.isBitPerfect ? "Bit-Perfect" : "Converted")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(player.isBitPerfect ? .green : .yellow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                player.isBitPerfect
                                    ? Color.green.opacity(0.15)
                                    : Color.yellow.opacity(0.15)
                            )
                            .cornerRadius(3)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Source")
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundColor(.roonTertiary)
                            Text(player.sourceFormat.isEmpty ? "—" : player.sourceFormat)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.roonSecondary)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Output")
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundColor(.roonTertiary)
                            Text(player.outputFormat.isEmpty ? "—" : player.outputFormat)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.roonSecondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(10)
            .background(Color.roonSurface.opacity(0.8))
            .cornerRadius(6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Debug Toggle

struct AudioDebugToggle: View {
    @State private var showDebug = false

    var body: some View {
        VStack {
            if showDebug {
                AudioDebugView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            HStack {
                Spacer()
                Button(action: { withAnimation { showDebug.toggle() } }) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.roonSecondary)
                        .frame(width: 44, height: 44)
                        .background(Color.roonSurface)
                        .clipShape(Circle())
                }
                .padding(16)
            }
        }
    }
}

#Preview {
    ZStack {
        Color.roonBase.ignoresSafeArea()
        AudioDebugToggle()
    }
}
