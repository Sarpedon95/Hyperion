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
        let displayLines = buildDisplayLines(from: lines)
        return ZStack {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // AUDIT-FIX: replaced outer GeometryReader with
                        // containerRelativeFrame on the padding views — these are
                        // sized relative to the ScrollView's vertical container,
                        // which is exactly what the GR was measuring.
                        Color.clear
                            .containerRelativeFrame(.vertical) { value, _ in value * 0.38 }

                        ForEach(Array(displayLines.enumerated()), id: \.element.id) { idx, line in
                            lyricLine(line: line, index: idx, activeIndex: activeLineIndex)
                                .id(line.id)
                                .onTapGesture {
                                    if case .lyric(let ll) = line.kind {
                                        player.seek(to: ll.time)
                                    }
                                }
                        }

                        Color.clear
                            .containerRelativeFrame(.vertical) { value, _ in value * 0.55 }
                    }
                }
                .onChange(of: activeLineIndex) { _, newIndex in
                    guard newIndex < displayLines.count else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(displayLines[newIndex].id, anchor: .center)
                    }
                }
                .onChange(of: player.currentTime) { _, time in
                    let newIndex = lineIndex(for: time, in: displayLines)
                    if newIndex != activeLineIndex { activeLineIndex = newIndex }
                }
                .onAppear {
                    let idx = lineIndex(for: player.currentTime, in: displayLines)
                    activeLineIndex = idx
                    if idx < displayLines.count {
                        proxy.scrollTo(displayLines[idx].id, anchor: .center)
                    }
                }
            }

            // Top and bottom gradient masks
            VStack {
                LinearGradient(
                    colors: [Color(hex: "#0f1209"), Color(hex: "#0f1209").opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 80)
                .allowsHitTesting(false)
                Spacer()
                LinearGradient(
                    colors: [Color(hex: "#0f1209").opacity(0), Color(hex: "#0f1209")],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 80)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func lyricLine(line: DisplayLine, index: Int, activeIndex: Int) -> some View {
        let distance = abs(index - activeIndex)
        let isActive = distance == 0

        switch line.kind {
        case .lyric:
            let opacity: Double = isActive ? 1.0 : distance == 1 ? 0.38 : distance == 2 ? 0.20 : 0.12
            Text(line.text)
                .font(isActive
                    ? .system(size: 24, weight: .bold,    design: .default)
                    : .system(size: 20, weight: .regular, design: .default))
                .foregroundColor(.white.opacity(opacity))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.vertical, isActive ? 16 : 10)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.22), value: activeIndex)
                .contentShape(Rectangle())

        case .interlude:
            InterludeDots(isActive: isActive)
                .padding(.vertical, isActive ? 20 : 14)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.22), value: activeIndex)
        }
    }

    // MARK: - Plain lyrics view

    private func plainView(text: String) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                // "No sync" badge
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11))
                    Text("Lyrics available — no sync")
                        .font(.roonBody(11, weight: .medium))
                }
                .foregroundColor(.roonAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.roonAccent.opacity(0.15))
                .clipShape(Capsule())

                Text(text)
                    .font(.roonBody(17))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineSpacing(8)
                    .padding(.horizontal, 32)

                Button {
                    showManualSearch = true
                } label: {
                    Text("Search for synced lyrics")
                        .font(.roonBody(14, weight: .semibold))
                        .foregroundColor(.roonBase)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.roonAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 40)
                }
                .buttonStyle(.plain)
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
                Button(action: searchAction) {
                    Text("Search manually")
                        .font(.roonBody(14, weight: .semibold))
                        .foregroundColor(.roonBase)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.roonAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack(alignment: .top) {
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

                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - Display line model

    private enum DisplayLineKind {
        case lyric(LyricsLine)
        case interlude
    }

    private struct DisplayLine: Identifiable {
        let id: UUID
        let text: String
        let time: TimeInterval
        let kind: DisplayLineKind

        init(lyric: LyricsLine) {
            id = lyric.id
            text = lyric.text.trimmingCharacters(in: .whitespaces).isEmpty ? "•" : lyric.text
            time = lyric.time
            kind = .lyric(lyric)
        }

        init(interludeAt time: TimeInterval) {
            id = UUID()
            text = "•••"
            self.time = time
            kind = .interlude
        }
    }

    private func buildDisplayLines(from lines: [LyricsLine]) -> [DisplayLine] {
        var result: [DisplayLine] = []
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let gap = line.time - lines[i - 1].time
                if gap > 8 {
                    result.append(DisplayLine(interludeAt: lines[i - 1].time + gap / 2))
                }
            }
            result.append(DisplayLine(lyric: line))
        }
        return result
    }

    // MARK: - Helpers

    private func lineIndex(for time: TimeInterval, in lines: [DisplayLine]) -> Int {
        let adjusted = time + 0.3
        var result = 0
        for (i, line) in lines.enumerated() {
            if line.time <= adjusted { result = i } else { break }
        }
        return result
    }

    private func loadLyrics() async {
        // Serve from memory instantly if the track was prefetched on play start.
        if let cached = LyricsService.shared.cachedResult(trackID: track.id) {
            withAnimation(.easeIn(duration: 0.2)) { loadState = .loaded(cached) }
            return
        }

        withAnimation(.easeOut(duration: 0.15)) { loadState = .loading }
        activeLineIndex = 0

        let artist = track.composer ?? track.albumartist ?? track.trackartist ?? ""
        let title  = track.work.flatMap { $0.isEmpty ? nil : $0 } ?? track.title
        let album  = track.album ?? ""

        let result = await LyricsService.shared.lyrics(
            artistName: artist.isEmpty ? (track.albumartist ?? track.title) : artist,
            trackName:  title,
            albumName:  album.isEmpty ? nil : album,
            duration:   (track.duration ?? 0) > 0 ? track.duration : nil,
            trackID:    track.id
        )

        withAnimation(.easeIn(duration: 0.2)) {
            loadState = .loaded(result)
        }
    }

    private func pinAndReload(_ candidate: LyricsCandidate) {
        let artist = track.composer ?? track.albumartist ?? track.trackartist ?? ""
        let artistResolved = artist.isEmpty ? (track.albumartist ?? track.title) : artist
        let title  = track.work.flatMap { $0.isEmpty ? nil : $0 } ?? track.title
        let album  = track.album ?? ""
        LyricsService.shared.pinResult(
            candidate: candidate,
            trackID:   track.id,
            artist:    artistResolved,
            track:     title,
            album:     album
        )
        withAnimation(.easeIn(duration: 0.2)) {
            loadState = .loaded(candidate.result)
        }
    }
}

// MARK: - Interlude dots animation (TimelineView for 60fps smooth pulsing)

private struct InterludeDots: View {
    let isActive: Bool

    var body: some View {
        // .animation schedule drives at display refresh rate when active,
        // .paused emits a single update so the view renders once while inactive.
        TimelineView(.animation(paused: !isActive)) { context in
            let t = context.date.timeIntervalSince1970
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(dotOpacity(dot: i, time: t)))
                        .frame(width: isActive ? 8 : 5, height: isActive ? 8 : 5)
                }
            }
        }
    }

    // Each dot has a 0.4s peak window inside a 1.2s cycle.
    // Returns 0.9 at peak, falling smoothly to 0.15 as another dot takes over.
    private func dotOpacity(dot: Int, time: TimeInterval) -> Double {
        guard isActive else { return 0.15 }
        let cycle: Double = 1.2
        let t = time.truncatingRemainder(dividingBy: cycle)
        let peak = Double(dot) * 0.4
        // Wrap-aware distance to peak
        let diff = min(abs(t - peak), min(abs(t - peak + cycle), abs(t - peak - cycle)))
        let raw = max(0.0, 1.0 - diff / 0.4)
        return 0.15 + raw * 0.75
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
            track.work.flatMap { $0.isEmpty ? nil : $0 } ?? track.title
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
        .bottomOverlayAwareScroll()
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
