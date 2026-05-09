import SwiftUI

// Sheet shown when radio mode is active.
// Displays the seed track, the current radio queue, and a Stop Radio button.

struct RadioSessionView: View {

    @ObservedObject private var player = PlayerViewModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.roonBase.ignoresSafeArea()

                VStack(spacing: 0) {
                    if let seed = player.radioSeed {
                        seedHeader(seed)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 20)
                    }

                    Divider().background(Color.roonBorder)

                    let radioTracks = upcomingRadioTracks
                    if radioTracks.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 36))
                                .foregroundColor(.roonSecondary)
                            Text("Fetching more tracks…")
                                .font(.roonBody(15))
                                .foregroundColor(.roonSecondary)
                        }
                        Spacer()
                    } else {
                        List {
                            ForEach(radioTracks) { track in
                                RadioQueueRow(track: track, isCurrent: track.id == player.currentTrack?.id)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparatorTint(Color.roonBorder)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }

                    Divider().background(Color.roonBorder)

                    Button {
                        Haptics.medium()
                        player.stopRadio()
                        dismiss()
                    } label: {
                        Label("Stop Radio", systemImage: "stop.circle")
                            .font(.roonBody(16, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.roonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.roonAccent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    private func seedHeader(_ seed: Track) -> some View {
        HStack(spacing: 14) {
            ArtworkView(coverid: seed.coverid, size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Label("Radio seed", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.roonBody(11, weight: .medium))
                    .foregroundColor(.roonAccent)

                Text(seed.title)
                    .font(.roonBody(15, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)

                if let artist = seed.albumartist ?? seed.trackartist {
                    Text(artist)
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Queue items from the current position onward (excluding the seed if it was first)
    private var upcomingRadioTracks: [Track] {
        guard !player.queue.isEmpty else { return [] }
        let from = max(0, player.currentIndex)
        return Array(player.queue[from...])
    }
}

private struct RadioQueueRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(coverid: track.coverid, size: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    isCurrent ? RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.roonAccent, lineWidth: 1.5) : nil
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.roonBody(14, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(isCurrent ? .roonAccent : .roonPrimary)
                    .lineLimit(1)
                if let artist = track.albumartist ?? track.trackartist {
                    Text(artist)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .foregroundColor(.roonAccent)
                    .symbolEffect(.variableColor.iterative)
            }
        }
        .padding(.vertical, 4)
    }
}
