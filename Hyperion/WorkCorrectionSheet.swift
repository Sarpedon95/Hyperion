import SwiftUI

// MARK: - Work Correction Sheet

/// Two-phase sheet for manually linking a WorkGroup to an OpenOpus work.
/// Phase 1: search for composer by name.
/// Phase 2: browse / filter that composer's works and confirm a selection.
struct WorkCorrectionSheet: View {

    let group: WorkGroup
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // Phase tracking
    @State private var phase: Phase = .composerSearch

    // Composer search
    @State private var composerQuery: String = ""
    @State private var composers: [OOComposer] = []
    @State private var composerTask: Task<Void, Never>? = nil
    @State private var isLoadingComposers: Bool = false
    @State private var composerError: String? = nil

    // Work browse
    @State private var selectedComposer: OOComposer? = nil
    @State private var workQuery: String = ""
    @State private var allWorks: [OOWork] = []
    @State private var isLoadingWorks: Bool = false
    @State private var workError: String? = nil

    // Confirmation
    @State private var selectedWork: OOWork? = nil
    @State private var showConfirm: Bool = false
    @State private var didSave: Bool = false

    private var albumID: Int { group.tracks.first?.albumID ?? 0 }

    private enum Phase { case composerSearch, workBrowse }

    // Filtered works list
    private var filteredWorks: [OOWork] {
        guard !workQuery.isEmpty else { return allWorks }
        let q = workQuery.lowercased()
        return allWorks.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .composerSearch:
                    composerSearchView
                case .workBrowse:
                    workBrowseView
                }
            }
            .navigationTitle(phase == .composerSearch ? "Fix Work Link" : (selectedComposer?.name ?? "Select Work"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .workBrowse {
                        Button("Back") {
                            phase = .composerSearch
                            selectedComposer = nil
                            allWorks = []
                            workQuery = ""
                        }
                    } else {
                        Button("Cancel") {
                            onDismiss?()
                            dismiss()
                        }
                    }
                }
            }
            .background(Color.roonBase.ignoresSafeArea())
        }
        .onAppear {
            // Pre-fill composer name from the work group
            composerQuery = group.composer ?? ""
            triggerComposerSearch(composerQuery)
        }
        .confirmationDialog(
            "Link to \"\(selectedWork?.title ?? "")\"?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Confirm Link") { saveOverride() }
            Button("Cancel", role: .cancel) { selectedWork = nil }
        } message: {
            if let composer = selectedComposer {
                Text("This will associate \"\(group.workTitle)\" (album \(albumID)) with the OpenOpus work by \(composer.name).")
            }
        }
    }

    // MARK: - Phase 1: Composer search

    private var composerSearchView: some View {
        List {
            Section {
                TextField("Composer name", text: $composerQuery)
                    .autocorrectionDisabled()
                    .onChange(of: composerQuery) { _, q in triggerComposerSearch(q) }
            }

            if isLoadingComposers {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                .listRowBackground(Color.roonSurface)
            } else if let err = composerError {
                Section {
                    Text(err)
                        .font(.roonBody(13))
                        .foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)
            } else if composers.isEmpty && !composerQuery.isEmpty {
                Section {
                    Text("No composers found")
                        .font(.roonBody(13))
                        .foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)
            } else {
                Section("Results") {
                    ForEach(composers) { composer in
                        Button {
                            Haptics.light()
                            selectComposer(composer)
                        } label: {
                            ComposerRow(composer: composer)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.roonSurface)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
    }

    // MARK: - Phase 2: Work browse

    private var workBrowseView: some View {
        List {
            Section {
                TextField("Filter works", text: $workQuery)
                    .autocorrectionDisabled()
            }

            if isLoadingWorks {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                .listRowBackground(Color.roonSurface)
            } else if let err = workError {
                Section {
                    Text(err)
                        .font(.roonBody(13))
                        .foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)
            } else if filteredWorks.isEmpty {
                Section {
                    Text(workQuery.isEmpty ? "No works found" : "No matching works")
                        .font(.roonBody(13))
                        .foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)
            } else {
                Section("\(filteredWorks.count) work\(filteredWorks.count == 1 ? "" : "s")") {
                    ForEach(filteredWorks) { work in
                        Button {
                            Haptics.light()
                            selectedWork = work
                            showConfirm = true
                        } label: {
                            WorkRow(work: work)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.roonSurface)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
    }

    // MARK: - Actions

    private func triggerComposerSearch(_ query: String) {
        composerTask?.cancel()
        composerError = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            composers = []
            isLoadingComposers = false
            return
        }
        isLoadingComposers = true
        composerTask = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000) // debounce
                guard !Task.isCancelled else { return }
                let results = try await OpenOpusService.shared.searchComposers(name: query)
                await MainActor.run {
                    composers = results
                    isLoadingComposers = false
                }
            } catch is CancellationError {
                // swallow
            } catch {
                await MainActor.run {
                    composerError = error.localizedDescription
                    isLoadingComposers = false
                }
            }
        }
    }

    private func selectComposer(_ composer: OOComposer) {
        selectedComposer = composer
        isLoadingWorks = true
        workError = nil
        phase = .workBrowse
        Task {
            do {
                let works = try await OpenOpusService.shared.worksForComposer(composer.id)
                await MainActor.run {
                    allWorks = works.sorted { $0.title < $1.title }
                    isLoadingWorks = false
                    // Pre-fill filter with the work title to help user find the right one
                    if !group.workTitle.isEmpty {
                        workQuery = group.workTitle
                    }
                }
            } catch {
                await MainActor.run {
                    workError = error.localizedDescription
                    isLoadingWorks = false
                }
            }
        }
    }

    @MainActor
    private func saveOverride() {
        guard let work = selectedWork else { return }
        OOUserLinkOverrideStore.shared.create(
            workID: work.id,
            albumID: albumID,
            note: "User linked from album detail: \(group.workTitle)"
        )
        Haptics.medium()
        onDismiss?()
        dismiss()
    }
}

// MARK: - Composer row

private struct ComposerRow: View {
    let composer: OOComposer

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(composer.name)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonPrimary)
                if let epoch = composer.epoch, !epoch.isEmpty {
                    Text(epoch.capitalized)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Work row

private struct WorkRow: View {
    let work: OOWork

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(work.title)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                Spacer()
                if work.isPopular {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.roonAccent)
                }
            }
            if let subtitle = work.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)
            }
            if let genre = work.genre, !genre.isEmpty {
                Text(genre.capitalized)
                    .font(.roonBody(10, weight: .semibold))
                    .foregroundColor(.roonTertiary)
                    .kerning(0.5)
            }
        }
        .padding(.vertical, 2)
    }
}
