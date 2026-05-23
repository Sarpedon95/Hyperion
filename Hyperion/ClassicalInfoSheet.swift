import SwiftUI

/// Read-only detail sheet shown from the Now Playing toolbar when the
/// current track has classical metadata. Surfaces the full work title,
/// performers, recording year, and (for opera/oratorio) section info
/// without truncation. All text is selectable; swipe-down dismisses.
struct ClassicalInfoSheet: View {

    let metadata: ClassicalMetadata

    @Environment(\.dismiss) private var dismiss

    private var hasPerformers: Bool {
        metadata.composer != nil
            || metadata.conductor != nil
            || metadata.ensemble != nil
            || !metadata.soloists.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                workSection
                if hasPerformers { performersSection }
                if metadata.recordingYear != nil { recordingSection }
                if metadata.section != nil { sectionSection }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Work Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.roonBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.roonAccent)
                        .fontWeight(.semibold)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var workSection: some View {
        Section {
            if let work = metadata.work {
                Text(work)
                    .font(.roonBody(16, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let slug = metadata.workID_slug {
                HStack(spacing: 6) {
                    Text(slug)
                        .font(.roonMono(11))
                        .foregroundColor(.roonTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.white.opacity(0.08))
                        )
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        } header: {
            Text("WORK")
        }
        .listRowBackground(Color.roonSurface)
    }

    @ViewBuilder
    private var performersSection: some View {
        Section {
            if let composer = metadata.composer {
                infoRow(label: "Composer", value: composer)
            }
            if let conductor = metadata.conductor {
                infoRow(label: "Conductor", value: conductor)
            }
            if let ensemble = metadata.ensemble {
                infoRow(label: "Ensemble", value: ensemble)
            }
            if !metadata.soloists.isEmpty {
                soloistsRow
            }
        } header: {
            Text("PERFORMERS")
        }
        .listRowBackground(Color.roonSurface)
    }

    @ViewBuilder
    private var recordingSection: some View {
        Section {
            if let year = metadata.recordingYear {
                infoRow(label: "Year", value: String(year))
            }
        } header: {
            Text("RECORDING")
        }
        .listRowBackground(Color.roonSurface)
    }

    @ViewBuilder
    private var sectionSection: some View {
        Section {
            if let section = metadata.section {
                infoRow(label: "Act/Part", value: section)
            }
        } header: {
            Text("SECTION")
        }
        .listRowBackground(Color.roonSurface)
    }

    // MARK: - Row helpers

    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(.roonSecondary)
                .kerning(0.8)
            Text(value)
                .font(.roonBody(15))
                .foregroundColor(.roonPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var soloistsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Soloists")
                .font(.roonBody(11, weight: .semibold))
                .foregroundColor(.roonSecondary)
                .kerning(0.8)
            ForEach(metadata.soloists, id: \.self) { name in
                Text(name)
                    .font(.roonBody(15))
                    .foregroundColor(.roonPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}
