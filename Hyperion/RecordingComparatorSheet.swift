import SwiftUI

// MARK: - Recording Comparator

/// Side-by-side list of every library recording for a single OpenOpus work.
/// Shown from OOWorkDetailView when 2+ candidates exist for the same work_id.
struct RecordingComparatorSheet: View {
    let work: OOWork
    let candidates: [WorkRecordingCandidate]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = PlayerViewModel.shared
    @ObservedObject private var library = LibraryViewModel.shared

    @State private var loadedTracks: [Int: [Track]] = [:] // albumID → tracks
    @State private var loadingIDs: Set<Int> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your library has \(candidates.count) recordings of this work. Tap any to queue it.")
                        .font(.roonBody(13))
                        .foregroundColor(.roonSecondary)
                        .listRowBackground(Color.roonSurface)
                }

                ForEach(candidates) { candidate in
                    ComparatorRow(
                        candidate: candidate,
                        tracks: loadedTracks[candidate.lmsAlbumID],
                        isLoading: loadingIDs.contains(candidate.lmsAlbumID)
                    ) {
                        playCandidate(candidate)
                    }
                    .listRowBackground(Color.roonSurface)
                    .listRowSeparatorTint(Color.roonBorder)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Compare Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.roonAccent)
                }
            }
        }
        .task {
            await loadAllTracks()
        }
    }

    private func loadAllTracks() async {
        for candidate in candidates {
            guard loadedTracks[candidate.lmsAlbumID] == nil else { continue }
            loadingIDs.insert(candidate.lmsAlbumID)
            if let tracks = try? await library.getTracksForAlbum(candidate.lmsAlbumID) {
                await MainActor.run {
                    loadedTracks[candidate.lmsAlbumID] = tracks
                    loadingIDs.remove(candidate.lmsAlbumID)
                }
            } else {
                await MainActor.run { loadingIDs.remove(candidate.lmsAlbumID) }
            }
        }
    }

    private func playCandidate(_ candidate: WorkRecordingCandidate) {
        Haptics.medium()
        let tracks = loadedTracks[candidate.lmsAlbumID] ?? []
        if tracks.isEmpty {
            // Fallback: request tracks and play when ready
            Task {
                if let t = try? await library.getTracksForAlbum(candidate.lmsAlbumID), !t.isEmpty {
                    await MainActor.run { player.playTracks(t) }
                }
            }
        } else {
            player.playTracks(tracks)
        }
        dismiss()
    }
}

// MARK: - Row

private struct ComparatorRow: View {
    let candidate: WorkRecordingCandidate
    let tracks: [Track]?
    let isLoading: Bool
    let onPlay: () -> Void

    private var conductor: String? {
        // Try to extract conductor from performer summary or album name
        let summary = candidate.performerSummary ?? ""
        let lines = summary.split(separator: "\n").map(String.init)
        return lines.first(where: { $0.lowercased().contains("conductor") ||
                                    $0.lowercased().contains("dir.") })
    }

    private var ensemble: String? {
        let summary = candidate.performerSummary ?? ""
        let keywords = ["orchestra", "philharmonic", "symphony", "chamber",
                        "ensemble", "quartet", "trio", "choir", "chorale"]
        let lines = summary.split(separator: "\n").map(String.init)
        return lines.first(where: { line in
            keywords.contains { line.lowercased().contains($0) }
        })
    }

    private var totalDuration: Double {
        (tracks ?? []).compactMap(\.duration).reduce(0, +)
    }

    private var year: Int? {
        tracks?.compactMap(\.year).first
    }

    private var format: String {
        let isLossless = tracks?.first?.lossless
        if isLossless == true { return "Lossless" }
        if isLossless == false { return "Lossy" }
        return ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(coverid: candidate.artworkTrackID, size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.lmsAlbumName)
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)

                if let c = conductor {
                    Label(c, systemImage: "person")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                } else if let e = ensemble {
                    Label(e, systemImage: "music.quarternote.3")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                } else if let summary = candidate.performerSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if let y = year { Text(String(y)).font(.roonMono(11)).foregroundColor(.roonTertiary) }
                    if !format.isEmpty { Text(format).font(.roonMono(11)).foregroundColor(.roonTertiary) }
                    if totalDuration > 0 {
                        Text(TimeFormatting.formatDuration(totalDuration))
                            .font(.roonMono(11)).foregroundColor(.roonTertiary)
                    }
                    if isLoading { ProgressView().scaleEffect(0.7) }
                }
            }

            Spacer(minLength: 0)

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.roonAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
