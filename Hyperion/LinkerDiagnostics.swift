import Foundation
import SwiftUI

// MARK: - Logging

/// Debug-only log that prefixes with [Linker] and prints to console.
func linkerLog(_ message: String) {
#if DEBUG
    print("[Linker] \(message)")
#endif
}

// MARK: - Diagnostics snapshot

struct LinkerDiagnostics {

    let albumsIndexed: Int
    let worksWithCandidates: Int
    let totalCandidates: Int
    let highConfidence: Int        // ≥ 0.75
    let mediumConfidence: Int      // 0.50–0.74
    let lowConfidence: Int         // < 0.50
    let userConfirmed: Int
    let userRejected: Int
    let cacheVersion: String
    let lastRebuilt: Date?

    var coveragePercent: Double {
        guard albumsIndexed > 0 else { return 0 }
        return Double(worksWithCandidates) / Double(albumsIndexed) * 100
    }

    @MainActor
    static func snapshot(
        linker: LMSLibraryLinker,
        overrides: OOUserLinkOverrideStore,
        albumCount: Int
    ) -> LinkerDiagnostics {
        let all = linker.candidatesByWork.values.flatMap { $0 }
        let high   = all.filter { $0.confidence >= 0.75 }.count
        let medium = all.filter { $0.confidence >= 0.50 && $0.confidence < 0.75 }.count
        let low    = all.filter { $0.confidence < 0.50 }.count

        return LinkerDiagnostics(
            albumsIndexed: albumCount,
            worksWithCandidates: linker.candidatesByWork.count,
            totalCandidates: all.count,
            highConfidence: high,
            mediumConfidence: medium,
            lowConfidence: low,
            userConfirmed: overrides.overrides.filter { $0.action == .confirmed || $0.action == .created }.count,
            userRejected: overrides.overrides.filter { $0.action == .rejected }.count,
            cacheVersion: linker.cacheVersion,
            lastRebuilt: linker.lastRebuilt
        )
    }
}

// MARK: - Debug diagnostics view (Debug builds only)

#if DEBUG
struct LinkerDiagnosticsView: View {

    @ObservedObject private var linker = LMSLibraryLinker.shared
    private let overrides = OOUserLinkOverrideStore.shared
    @State private var albumCount: Int = 0
    @State private var showRebuildConfirm: Bool = false

    var body: some View {
        let diag = LinkerDiagnostics.snapshot(
            linker: linker,
            overrides: overrides,
            albumCount: albumCount
        )
        List {
            Section("Index Coverage") {
                row("Albums in library", "\(diag.albumsIndexed)")
                row("OO works linked", "\(diag.worksWithCandidates)")
                row("Total candidates", "\(diag.totalCandidates)")
                row("Coverage", String(format: "%.1f%%", diag.coveragePercent))
            }
            Section("Confidence Breakdown") {
                row("High (≥0.75)", "\(diag.highConfidence)", color: .green)
                row("Medium (0.50–0.74)", "\(diag.mediumConfidence)", color: .yellow)
                row("Low (<0.50)", "\(diag.lowConfidence)", color: .orange)
            }
            Section("User Corrections") {
                row("Confirmed", "\(diag.userConfirmed)", color: .green)
                row("Rejected", "\(diag.userRejected)", color: .red)
            }
            Section("Cache") {
                row("Version", diag.cacheVersion)
                if let d = diag.lastRebuilt {
                    row("Last rebuilt", RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))
                } else {
                    row("Last rebuilt", "never")
                }
                row("Status", linker.isLinking ? "linking…" : "idle")
            }
            Section {
                Button(linker.isLinking ? "Rebuilding…" : "Force Rebuild Now") {
                    showRebuildConfirm = true
                }
                .disabled(linker.isLinking)
                .foregroundColor(linker.isLinking ? .secondary : .orange)
            } header: {
                Text("Actions")
            } footer: {
                Text("Clears the freshness guard and re-indexes all albums from LMS. Takes several minutes on large libraries.")
            }
            Section("Top Candidates") {
                ForEach(
                    linker.candidatesByWork.values
                        .compactMap(\.first)
                        .sorted { $0.confidence > $1.confidence }
                        .prefix(20),
                    id: \.id
                ) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.workTitle)
                            .font(.caption.weight(.medium))
                        Text("\(c.lmsAlbumName) — \(String(format: "%.0f%%", c.confidence * 100))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(c.matchReason)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Linker Diagnostics")
        .confirmationDialog(
            "Force rebuild will re-fetch all albums from LMS and re-run the full matching pipeline. This may take several minutes.",
            isPresented: $showRebuildConfirm,
            titleVisibility: .visible
        ) {
            Button("Rebuild Now", role: .destructive) {
                linker.forceRebuild()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            albumCount = (try? await LyrionAPI.shared.getAlbumsCount()) ?? 0
        }
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).foregroundColor(color).fontWeight(.medium)
        }
    }
}
#endif
