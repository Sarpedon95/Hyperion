import SwiftUI
import UIKit

// MARK: - Search

struct SearchView: View {

    @ObservedObject private var library = LibraryViewModel.shared
    @State private var searchText: String = ""
    @State private var searchResults: (composers: [Composer], works: [Work], albums: [Album]) = ([], [], [])
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searchSequence: Int = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Search")
                    .font(.roonTitle(34))
                    .foregroundColor(.roonPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                SearchInputField(text: $searchText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                Group {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SearchSuggestionsView()
                    } else if isSearching {
                        ProgressView()
                            .tint(.roonAccent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searchResults.composers.isEmpty
                                && searchResults.works.isEmpty
                                && searchResults.albums.isEmpty {
                        NoResultsView(query: searchText)
                    } else {
                        SearchResultsView(results: searchResults)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.roonBase.ignoresSafeArea())
            // Same transparent-nav-bar fix as HomeView — see comment there.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onChange(of: searchText) { _, newValue in performSearch(query: newValue) }
            .task {
                // Ensure composers are loaded for the suggestions panel.
                // This is a no-op if ContentView.task already loaded them.
                if library.composers.isEmpty { await library.loadComposers() }
            }
            .onDisappear {
                searchTask?.cancel()
                searchTask    = nil
                isSearching   = false
                searchResults = ([], [], [])
            }
        }
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        searchSequence += 1
        let sequence = searchSequence
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = ([], [], [])
            isSearching   = false
            return
        }
        // Mark searching immediately so the spinner shows, but keep the old
        // results visible during the debounce window — this prevents an
        // ugly flash of "No results" between keystrokes.
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, searchSequence == sequence else { return }

            // Clear stale results only after the debounce fires, so the
            // transition is: spinner → results, not: results → blank → results.
            searchResults = ([], [], [])
            let results = await library.search(query: trimmed)
            guard !Task.isCancelled, searchSequence == sequence else { return }

            searchResults = results
            isSearching   = false
        }
    }
}

// MARK: - Search input field

struct SearchInputField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.roonTertiary)
                .font(.system(size: 16))
            TextField("Albums, composers, works…", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .foregroundColor(.roonPrimary)
                .font(.roonBody(16))
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.roonTertiary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Removes the current search query")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.roonSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(focused ? Color.roonAccent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private func composerInitials(_ name: String) -> String { NameFormatting.initials(name) }
private func composerLastName(_ name: String) -> String { NameFormatting.lastName(name) }

// MARK: - Suggestions

struct SearchSuggestionsView: View {

    @ObservedObject private var library = LibraryViewModel.shared

    private let pinnedNames = [
        "Bach", "Beethoven", "Brahms", "Mozart", "Schubert",
        "Tchaikovsky", "Mahler", "Bruckner", "Wagner", "Sibelius",
        "Handel", "Vivaldi", "Haydn", "Chopin", "Liszt"
    ]

    // PERF: The original `pinnedComposers` and `allComposers` were computed
    // properties — O(n × pinnedNames.count) string-folding comparisons executed
    // on EVERY SwiftUI render pass. With a large library any published-property
    // change (isLoadingComposers, etc.) would re-run the full scan.
    //
    // These @State caches are rebuilt only when library.composers changes (a
    // true list update), which is at most once per app launch / refresh.
    @State private var cachedPinnedComposers: [Composer] = []
    @State private var cachedOtherComposers:  [Composer] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !cachedPinnedComposers.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Popular Composers")
                            .font(.roonTitle(22))
                            .foregroundColor(.roonPrimary)
                            .padding(.horizontal, 20)
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(cachedPinnedComposers) { composer in
                                NavigationLink {
                                    WorkListView(composerID: composer.id, composerName: composer.artist)
                                } label: {
                                    ComposerSuggestionCard(composer: composer)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !cachedOtherComposers.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("All Composers")
                                .font(.roonTitle(22))
                                .foregroundColor(.roonPrimary)
                            Spacer()
                            NavigationLink("See All") { ComposerListView() }
                                .font(.roonBody(14, weight: .semibold))
                                .foregroundColor(.roonAccent)
                        }
                        .padding(.horizontal, 20)
                        LazyVStack(spacing: 0) {
                            ForEach(cachedOtherComposers) { composer in
                                NavigationLink {
                                    WorkListView(composerID: composer.id, composerName: composer.artist)
                                } label: {
                                    ComposerSmallRow(composer: composer)
                                }
                                .buttonStyle(.plain)
                                if composer.id != cachedOtherComposers.last?.id {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                if library.isLoadingComposers {
                    HStack { Spacer(); ProgressView().tint(.roonAccent); Spacer() }
                }
                Spacer(minLength: 40)
            }
            .padding(.top, 4)
        }
        .background(Color.roonBase)
        .scrollContentBackground(.hidden)
        .onAppear {
            rebuildCaches(library.composers)
        }
        .onChange(of: library.composers) { _, composers in
            rebuildCaches(composers)
        }
    }

    private func rebuildCaches(_ composers: [Composer]) {
        let pinned = pinnedNames.compactMap { name in
            composers.first { SearchTextNormalizer.matches($0.artist, query: name) }
        }
        let pinnedIDs = Set(pinned.map(\.id))
        cachedPinnedComposers = pinned
        cachedOtherComposers  = Array(composers.filter { !pinnedIDs.contains($0.id) }.prefix(80))
    }
}

struct ComposerSuggestionCard: View {
    let composer: Composer
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.roonElevated).frame(width: 44, height: 44)
                Text(composerInitials(composer.artist))
                    .font(.roonTitle(14))
                    .foregroundColor(.roonAccent)
            }
            Text(composerLastName(composer.artist))
                .font(.roonBody(15, weight: .medium))
                .foregroundColor(.roonPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.roonSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ComposerSmallRow: View {
    let composer: Composer
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.roonElevated).frame(width: 38, height: 38)
                Text(composerInitials(composer.artist))
                    .font(.roonTitle(12))
                    .foregroundColor(.roonAccent)
            }
            .padding(.leading, 4)
            Text(composer.artist)
                .font(.roonBody(15, weight: .medium))
                .foregroundColor(.roonPrimary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.roonTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    let results: (composers: [Composer], works: [Work], albums: [Album])
    @ObservedObject private var library = LibraryViewModel.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !results.albums.isEmpty {
                    SearchSectionTitle("ALBUMS")
                    LazyVStack(spacing: 0) {
                        ForEach(results.albums) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                AlbumListRow(album: album)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            // Prefetch tracks on press-down so detail opens instantly.
                            .simultaneousGesture(DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    Task { try? await library.getTracksForAlbum(album.id) }
                                }
                            )
                            if album.id != results.albums.last?.id {
                                Color.roonBorder.frame(height: 0.5).padding(.leading, 68)
                            }
                        }
                    }
                    .background(Color.roonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                if !results.composers.isEmpty {
                    SearchSectionTitle("COMPOSERS")
                    LazyVStack(spacing: 0) {
                        ForEach(results.composers) { composer in
                            NavigationLink {
                                WorkListView(composerID: composer.id, composerName: composer.artist)
                            } label: {
                                ComposerSmallRow(composer: composer)
                            }
                            .buttonStyle(.plain)
                            if composer.id != results.composers.last?.id {
                                Color.roonBorder.frame(height: 0.5).padding(.leading, 64)
                            }
                        }
                    }
                    .background(Color.roonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                if !results.works.isEmpty {
                    SearchSectionTitle("WORKS")
                    LazyVStack(spacing: 0) {
                        ForEach(results.works) { work in
                            NavigationLink {
                                WorkDetailView(work: work)
                            } label: {
                                WorkRowView(work: work, showComposer: true)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            if work.id != results.works.last?.id {
                                Color.roonBorder.frame(height: 0.5).padding(.leading, 82)
                            }
                        }
                    }
                    .background(Color.roonSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 4)
        }
        .background(Color.roonBase)
        .scrollContentBackground(.hidden)
    }
}

struct SearchSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.roonBody(11, weight: .semibold))
            .foregroundColor(.roonAccent)
            .kerning(1.4)
            .padding(.horizontal, 20)
            .padding(.top, 4)
    }
}

struct NoResultsView: View {
    let query: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.roonTertiary)
            Text("No results for \"\(query)\"")
                .font(.roonTitle(18))
                .foregroundColor(.roonPrimary)
            Text("Try an album, composer, or work title")
                .font(.roonBody(14))
                .foregroundColor(.roonSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.roonBase)
    }
}

// MARK: - Settings

struct SettingsView: View {

    @ObservedObject private var connection = ConnectionManager.shared
    @ObservedObject private var serverLogs = ServerLogStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var localURL: String     = ""
    @State private var tailscaleURL: String = ""
    @State private var proxyURL: String     = ""
    @State private var selectedMode: ConnectionMode   = .auto
    @State private var isTestingConnection: Bool      = false
    @State private var connectionTestResult: Bool?    = nil
    @State private var connectionTestMessage: String? = nil
    @State private var logsCopied: Bool = false
    @State private var connectionTestTask: Task<Void, Never>? = nil
    @State private var connectionTestID: UUID? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $selectedMode) {
                        ForEach(ConnectionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .foregroundColor(.roonPrimary)
                } header: { Text("CONNECTION MODE") }
                .listRowBackground(Color.roonSurface)

                Section {
                    SettingsTextField(label: "Home",      placeholder: "http://192.168.1.x:9000",   text: $localURL)
                    SettingsTextField(label: "Tailscale", placeholder: "http://100.x.x.x:9000",     text: $tailscaleURL)
                    SettingsTextField(label: "Remote",    placeholder: "https://lyrion.domain.com", text: $proxyURL)
                } header: { Text("SERVER ADDRESSES") } footer: {
                    Text("For remote use, enter your public HTTPS reverse-proxy URL or Tailscale URL. You can paste either the base URL or the full /jsonrpc.js endpoint; Hyperion normalizes it automatically.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    Button { testConnection() } label: {
                        HStack {
                            Text("Test Connection").foregroundColor(.roonPrimary)
                            Spacer()
                            if isTestingConnection {
                                ProgressView().tint(.roonAccent)
                            } else if let result = connectionTestResult {
                                Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(result ? .green : .red)
                            }
                        }
                    }
                    .disabled(isTestingConnection)
                    if let connectionTestMessage {
                        Text(connectionTestMessage)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    HStack {
                        Text("Status").foregroundColor(.roonSecondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(connection.isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(connection.isConnected ? "Connected" : "Disconnected").foregroundColor(.roonPrimary)
                        }
                    }
                    HStack {
                        Text("Active URL").foregroundColor(.roonSecondary)
                        Spacer()
                        Text(connection.currentURL.isEmpty ? "Not set" : ServerLogStore.redactedURL(connection.currentURL))
                            .foregroundColor(.roonPrimary).lineLimit(1)
                            .font(.roonBody(13)).truncationMode(.middle)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last check").foregroundColor(.roonSecondary)
                        Text(connection.lastConnectionMessage)
                            .font(.roonBody(12))
                            .foregroundColor(.roonPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text("STATUS") }
                .listRowBackground(Color.roonSurface)

                Section {
                    if serverLogs.entries.isEmpty {
                        Text("No server diagnostics yet")
                            .foregroundColor(.roonSecondary)
                    } else {
                        ForEach(Array(serverLogs.entries.suffix(10))) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayLine)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(logColor(entry.level))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    HStack {
                        Button(logsCopied ? "Copied" : "Copy Logs") {
                            UIPasteboard.general.string = serverLogs.exportText
                            logsCopied = true
                        }
                        .foregroundColor(.roonAccent)
                        Spacer()
                        Button("Clear") {
                            serverLogs.clear()
                            logsCopied = false
                        }
                        .foregroundColor(.roonSecondary)
                    }
                } header: { Text("SERVER DIAGNOSTICS") } footer: {
                    Text("These entries also go to the system Console through os.Logger and include URL, HTTP status, RPC failures, timeout, TLS, DNS, and proxy/upstream errors.")
                        .font(.roonBody(12)).foregroundColor(.roonTertiary)
                }
                .listRowBackground(Color.roonSurface)

                Section {
                    HStack {
                        Text("Version").foregroundColor(.roonSecondary)
                        Spacer()
                        Text(appVersion).foregroundColor(.roonPrimary)
                    }
                    HStack {
                        Text("Engine").foregroundColor(.roonSecondary)
                        Spacer()
                        Text("Lyrion Music Server").foregroundColor(.roonPrimary)
                    }
                } header: { Text("ABOUT HYPERION") }
                .listRowBackground(Color.roonSurface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.roonBase)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.roonBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveSettings(); dismiss() }
                        .foregroundColor(.roonAccent).fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.roonSecondary)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                localURL     = connection.localURL
                tailscaleURL = connection.tailscaleURL
                proxyURL     = connection.proxyURL
                selectedMode = connection.connectionMode
            }
            .onDisappear {
                connectionTestTask?.cancel()
                connectionTestTask = nil
                connectionTestID = nil
                isTestingConnection = false
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func saveSettings() {
        let newLocal     = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTailscale = tailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let newProxy     = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let didChange = newLocal != connection.localURL
            || newTailscale != connection.tailscaleURL
            || newProxy != connection.proxyURL
            || selectedMode != connection.connectionMode

        connection.localURL       = newLocal
        connection.tailscaleURL   = newTailscale
        connection.proxyURL       = newProxy
        connection.connectionMode = selectedMode
        connection.saveSettings()

        guard didChange else { return }

        // Clear server-scoped data so a changed LMS endpoint never shows stale
        // albums/artwork from the previous library while reconnecting.
        LibraryViewModel.shared.clearCache()
<<<<<<< HEAD
        ArtworkCache.shared.clear(includeDiskCache: true)
=======
        ArtworkCache.shared.clear()
>>>>>>> 6d77a84 (Fixed general)
        connection.forceReconnect()
    }

    private func testConnection() {
        guard !isTestingConnection else { return }
        isTestingConnection  = true
        connectionTestResult = nil
        connectionTestMessage = nil
        logsCopied = false

        let mode  = selectedMode
        let local = localURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts    = tailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prox  = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)

        connectionTestTask?.cancel()
        let testID = UUID()
        connectionTestID = testID
        connectionTestTask = Task { @MainActor in
            defer {
                if connectionTestID == testID {
                    isTestingConnection = false
                    connectionTestTask = nil
                    connectionTestID = nil
                }
            }

            let probe: ConnectionProbeResult
            switch mode {
            case .local:
                probe = await ConnectionManager.probeBestServer(local, mode: .local)
            case .tailscale:
                probe = await ConnectionManager.probeBestServer(ts, mode: .tailscale)
            case .proxy:
                probe = await ConnectionManager.probeBestServer(prox, mode: .proxy)
            case .auto:
                let entries: [(String, ConnectionMode)] = [(local, .local), (ts, .tailscale), (prox, .proxy)]
                var seen = Set<String>()
                let candidates = entries
                    .flatMap { HyperionServerURL.candidateBases(for: $0.0, mode: $0.1) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
                if candidates.isEmpty {
                    probe = await ConnectionManager.probeBestServer("")
                } else {
                    // Reuse ConnectionManager's optimized candidate race so the
                    // Settings test behaves like Auto connection resolution and
                    // does not create a separate URLSession/socket pool per URL.
                    if let result = await ConnectionManager.probeFirstSuccessful(candidates: candidates) {
                        probe = result
                    } else {
                        probe = await ConnectionManager.probeServer("")
                    }
                }
            }

            guard !Task.isCancelled, connectionTestID == testID else { return }
            connectionTestResult = probe.isSuccess
            connectionTestMessage = probe.summary
        }
    }

    private func logColor(_ level: ServerLogLevel) -> Color {
        switch level {
        case .debug: return .roonTertiary
        case .info:  return .roonPrimary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}

struct SettingsTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.roonSecondary).frame(width: 70, alignment: .leading)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .foregroundColor(.roonPrimary)
        }
    }
}
