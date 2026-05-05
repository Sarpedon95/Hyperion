import SwiftUI

// Full-screen lyrics overlay for the current track.
// Displays time-synced lines (LRC) with active-line highlighting and
// auto-scroll, or falls back to plain text when no sync data is available.
// Source: LRCLIB (https://lrclib.net) — free, public, community-maintained.

struct LyricsView: View {

    let track: Track
    @ObservedObject private var player = PlayerViewModel.shared
    @Environment(\.dismiss) private var dismiss

    @State private var loadState: LyricsLoadState = .loading
    @State private var activeLineIndex: Int = 0
    @State private var showManualSearch: Bool = false

    var body: some View {
        ZStack {
            Color(hex: "#0f1209").ignoresSafeArea()
            contentLayer
        }
        .overlay(alignment: .top) { topBar }
        .preferredColorScheme(.dark)
        .task(id: track.id) { await loadLyrics() }
        .sheet(isPresented: $showManualSearch) {
            ManualLyricsSearchView(track: track) { candidate in
                Task { @MainActor in
                    pinAndReload(candidate)
                }
            }
        }
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var contentLayer: some View {
        switch loadState {
        case .loading:
            VStack(spacing: 14) {
                ProgressView().tint(.roonAccent)
                Text("Loading lyrics…")
                    .font(.roonBody(13))
                    .foregroundColor(.roonTertiary)
            }

        case .loaded(let result):
            switch result {
            case .synced(let lines):
                syncedView(lines: lines)
            case .plain(let text):
                plainView(text: text)
            case .instrumental:
                emptyState(icon: "pianokeys", primary: "Instrumental", secondary: nil)
            case .unavailable:
                emptyState(
                    icon: "music.note",
                    primary: "No lyrics available",
                    secondary: "Lyrics not found for this track.",
                    searchAction: { showManualSearch = true }
                )
            }
        }
    }

    // MARK: - Synced view

    private func syncedView(lines: [LyricsLine]) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Top padding so the first line starts centered.
                        Color.clear.frame(height: geo.size.height * 0.38)

                        ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                            lyricLine(text: line.text, index: idx)
                                .id(line.id)
                        }

                        // Bottom padding so the last line can scroll to center.
                        Color.clear.frame(height: geo.size.height * 0.55)
                    }
                }
                // Scroll to active line whenever it changes.
                .onChange(of: activeLineIndex) { _, newIndex in
                    guard newIndex < lines.count else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                        proxy.scrollTo(lines[newIndex].id, anchor: .center)
                    }
                }
                // Recompute active line on every playback-time tick.
                .onChange(of: player.currentTime) { _, time in
                    let newIndex = lineIndex(for: time, in: lines)
                    if newIndex != activeLineIndex { activeLineIndex = newIndex }
                }
                // Snap to current position immediately on appear — no animation.
                .onAppear {
                    let idx = lineIndex(for: player.currentTime, in: lines)
                    activeLineIndex = idx
                    if idx < lines.count {
                        proxy.scrollTo(lines[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    // Each lyric line adapts font/color based on its position relative to the
    // active line. The transition is driven by `activeLineIndex` only — not by
    // every `currentTime` tick — so the animation triggers at most once per line.
    @ViewBuilder
    private func lyricLine(text: String, index: Int) -> some View {
        let isActive = index == activeLineIndex
        let isPast   = index < activeLineIndex
        let display  = text.trimmingCharacters(in: .whitespaces).isEmpty ? "•" : text

        Text(display)
            .font(isActive
                ? .system(size: 24, weight: .bold,    design: .default)
                : .system(size: 20, weight: .regular, design: .default))
            .foregroundColor(
                isActive ? .white
                : isPast ? Color.white.opacity(0.22)
                         : Color.white.opacity(0.38)
            )
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.vertical, isActive ? 16 : 10)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.22), value: activeLineIndex)
            .contentShape(Rectangle())
    }

    // MARK: - Plain lyrics view

    private func plainView(text: String) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                Text(text)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineSpacing(8)
                    .padding(.horizontal, 32)

                HStack(spacing: 5) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10))
                        .foregroundColor(.roonTertiary)
                    Text("Not time-synced")
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                }
            }
            .padding(.top, 80)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Empty state

    private func emptyState(
        icon: String,
        primary: String,
        secondary: String?,
        searchAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.roonTertiary)
            Text(primary)
                .font(.roonBody(16, weight: .medium))
                .foregroundColor(.roonSecondary)
            if let secondary {
                Text(secondary)
                    .font(.roonBody(13))
                    .foregroundColor(.roonTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            if let searchAction {
                Button("Search manually", action: searchAction)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.roonAccent, lineWidth: 1)
                    )
                    .buttonStyle(.plain)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack(alignment: .top) {
            // Gradient fade so lyrics appear to scroll under the bar.
            LinearGradient(
                colors: [Color(hex: "#0f1209"), Color(hex: "#0f1209").opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 90)
            .allowsHitTesting(false)

            HStack(alignment: .center) {
                Button {
                    Haptics.light()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.84))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.16)))
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 2) {
                    Text("LYRICS")
                        .font(.roonBody(11, weight: .semibold))
                        .foregroundColor(.roonTertiary)
                        .kerning(1.4)
                    Text(track.title)
                        .font(.roonBody(13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.84))
                        .lineLimit(1)
                }

                Spacer()

                // Mirror of the close button to keep the title centered.
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func lineIndex(for time: TimeInterval, in lines: [LyricsLine]) -> Int {
        var result = 0
        for (i, line) in lines.enumerated() {
            if line.time <= time { result = i } else { break }
        }
        return result
    }

    private func loadLyrics() async {
        withAnimation(.easeOut(duration: 0.15)) { loadState = .loading }
        activeLineIndex = 0

        let artist = track.composer ?? track.albumartist ?? track.trackartist ?? ""
        let title  = track.work?.isEmpty == false ? track.work! : track.title
        let album  = track.album ?? ""

        let result = await LyricsService.shared.lyrics(
            artistName: artist.isEmpty ? (track.albumartist ?? track.title) : artist,
            trackName:  title,
            albumName:  album.isEmpty ? nil : album,
            duration:   (track.duration ?? 0) > 0 ? track.duration : nil
        )

        withAnimation(.easeIn(duration: 0.2)) {
            loadState = .loaded(result)
        }
    }

    private func pinAndReload(_ candidate: LyricsCandidate) {
        let artist = track.composer ?? track.albumartist ?? track.trackartist ?? ""
        let artistResolved = artist.isEmpty ? (track.albumartist ?? track.title) : artist
        let title  = track.work?.isEmpty == false ? track.work! : track.title
        let album  = track.album ?? ""
        LyricsService.shared.pinResult(
            candidate,
            artist: artistResolved,
            track:  title,
            album:  album
        )
        withAnimation(.easeIn(duration: 0.2)) {
            loadState = .loaded(candidate.result)
        }
    }
}

// MARK: - Load state

private enum LyricsLoadState {
    case loading
    case loaded(LyricsResult)
}

// MARK: - Manual lyrics search sheet

struct ManualLyricsSearchView: View {

    let track:  Track
    let onPin:  (LyricsCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var artist:      String
    @State private var title:       String
    @State private var candidates:  [LyricsCandidate] = []
    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false

    init(track: Track, onPin: @escaping (LyricsCandidate) -> Void) {
        self.track = track
        self.onPin = onPin
        let a = track.composer ?? track.albumartist ?? track.trackartist ?? ""
        _artist = State(initialValue: a)
        _title  = State(initialValue:
            (track.work?.isEmpty == false ? track.work! : nil) ?? track.title
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                fieldsSection
                Divider()
                resultsSection
            }
            .background(Color.roonBase.ignoresSafeArea())
            .navigationTitle("Search Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.roonAccent)
                }
            }
        }
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        VStack(spacing: 10) {
            fieldRow(label: "Artist", text: $artist)
            fieldRow(label: "Title",  text: $title)
            Button {
                Task { await search() }
            } label: {
                Text(isSearching ? "Searching…" : "Search")
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonBase)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.roonAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isSearching || artist.isEmpty || title.isEmpty)
            .opacity((isSearching || artist.isEmpty || title.isEmpty) ? 0.5 : 1)
        }
        .padding(16)
    }

    private func fieldRow(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.roonBody(13))
                .foregroundColor(.roonSecondary)
                .frame(width: 44, alignment: .trailing)
            TextField(label, text: text)
                .font(.roonBody(14))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.roonElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .submitLabel(.search)
                .onSubmit { Task { await search() } }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if isSearching {
            Spacer()
            ProgressView().tint(.roonAccent)
            Spacer()
        } else if candidates.isEmpty && hasSearched {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundColor(.roonTertiary)
                Text("No results found")
                    .font(.roonBody(14))
                    .foregroundColor(.roonTertiary)
            }
            Spacer()
        } else if !candidates.isEmpty {
            List(candidates) { c in
                Button {
                    Task { @MainActor in
                        onPin(c)
                        dismiss()
                    }
                } label: {
                    candidateRow(c)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.roonSurface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            Spacer()
        }
    }

    private func candidateRow(_ c: LyricsCandidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.trackName)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(2)
                Text(c.artistName)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)
                if let album = c.albumName, !album.isEmpty {
                    Text(album)
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                if c.hasSynced {
                    Text("SYNCED")
                        .font(.roonBody(9, weight: .semibold))
                        .foregroundColor(.roonAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.roonAccent.opacity(0.15))
                        .clipShape(Capsule())
                }
                if let dur = c.duration, dur > 0 {
                    Text(formatDuration(dur))
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func search() async {
        guard !artist.isEmpty, !title.isEmpty else { return }
        isSearching = true
        candidates  = await LyricsService.shared.searchCandidates(artist: artist, track: title)
        isSearching = false
        hasSearched = true
    }

    // MARK: - Formatting

    private func formatDuration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}
