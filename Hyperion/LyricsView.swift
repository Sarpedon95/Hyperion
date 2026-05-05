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

    var body: some View {
        ZStack {
            Color(hex: "#0f1209").ignoresSafeArea()
            contentLayer
        }
        .overlay(alignment: .top) { topBar }
        .preferredColorScheme(.dark)
        .task(id: track.id) { await loadLyrics() }
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
                    secondary: "Lyrics not found for this track."
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

    private func emptyState(icon: String, primary: String, secondary: String?) -> some View {
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
}

// MARK: - Load state

private enum LyricsLoadState {
    case loading
    case loaded(LyricsResult)
}
