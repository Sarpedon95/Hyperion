import SwiftUI
import Charts

// MARK: - Stats root

struct StatsView: View {

    @ObservedObject private var history = PlaybackHistoryStore.shared
    @ObservedObject private var player  = PlayerViewModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // MARK: Most Played Tracks
                statSection("Most Played Tracks") {
                    let tracks = history.mostPlayedTracks(limit: 10)
                    if tracks.isEmpty {
                        emptyLabel("No track plays recorded yet")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { rank, rec in
                                StatsTrackRow(rank: rank + 1, record: rec)
                                if rank < tracks.count - 1 {
                                    Color.roonBorder.frame(height: 0.5).padding(.leading, 68)
                                }
                            }
                        }
                        .background(Color.roonSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }
                }

                // MARK: Top Artists
                statSection("Top Artists") {
                    let sorted = history.artistPlayCounts
                        .sorted { $0.value > $1.value }
                        .prefix(8)
                    if sorted.isEmpty {
                        emptyLabel("No artist plays recorded yet")
                    } else {
                        Chart(sorted, id: \.key) { item in
                            BarMark(
                                x: .value("Plays", item.value),
                                y: .value("Artist", item.key)
                            )
                            .foregroundStyle(Color.roonAccent.gradient)
                            .cornerRadius(4)
                        }
                        .chartYAxis {
                            AxisMarks { _ in
                                AxisValueLabel()
                                    .font(.roonBody(11))
                                    .foregroundStyle(Color.roonSecondary)
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                                AxisValueLabel()
                                    .font(.roonMono(10))
                                    .foregroundStyle(Color.roonTertiary)
                            }
                        }
                        .frame(height: max(CGFloat(sorted.count) * 34, 80))
                        .padding(.horizontal, 20)
                    }
                }

                // MARK: Top Genres
                statSection("Top Genres") {
                    let sorted = history.genrePlayCounts
                        .sorted { $0.value > $1.value }
                        .prefix(6)
                    if sorted.isEmpty {
                        emptyLabel("No genre plays recorded yet")
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(Array(sorted), id: \.key) { item in
                                HStack(spacing: 6) {
                                    Text(item.key.capitalized)
                                        .font(.roonBody(13, weight: .medium))
                                        .foregroundColor(.roonPrimary)
                                    Text("\(item.value)")
                                        .font(.roonMono(11))
                                        .foregroundColor(.roonAccent)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.roonSurface)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(Color.roonBorder, lineWidth: 1))
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }

                // MARK: Listening Heatmap
                statSection("Listening Map") {
                    ListeningHeatmapView()
                        .padding(.horizontal, 16)
                }

                // MARK: Time of Day
                statSection("Time of Day") {
                    TimeOfDayView()
                        .padding(.horizontal, 16)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 12)
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.roonBase, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    @ViewBuilder
    private func statSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.roonTitle(20))
                .foregroundColor(.roonPrimary)
                .padding(.horizontal, 20)
            content()
        }
    }

    @ViewBuilder
    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.roonBody(14))
            .foregroundColor(.roonTertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
    }
}

// MARK: - Track row

private struct StatsTrackRow: View {
    let rank: Int
    let record: PlaybackHistoryStore.TrackPlayRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.roonMono(13, weight: .semibold))
                .foregroundColor(.roonTertiary)
                .frame(width: 24, alignment: .trailing)
                .padding(.leading, 16)

            ArtworkView(coverid: record.coverid, size: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.roonBody(14, weight: .medium))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                Text(record.artist.isEmpty ? record.album : record.artist)
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(record.playCount)")
                    .font(.roonMono(14, weight: .semibold))
                    .foregroundColor(.roonAccent)
                Text("plays")
                    .font(.roonBody(10))
                    .foregroundColor(.roonTertiary)
            }
            .padding(.trailing, 16)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Simple flow layout for genre chips

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let rowHeights: [CGFloat] = rows.map { row in
            row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        }
        let height = rowHeights.reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubview]] = [[]]
        var rowWidth: CGFloat = 0
        for subview in subviews {
            let w = subview.sizeThatFits(.unspecified).width
            if rowWidth + w > maxWidth, !rows[rows.endIndex - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.endIndex - 1].append(subview)
            rowWidth += w + spacing
        }
        return rows
    }
}

// MARK: - Listening Heatmap (GitHub-style calendar grid)

private struct ListeningHeatmapView: View {
    @ObservedObject private var history = PlaybackHistoryStore.shared
    @State private var selectedDay: String? = nil

    private let calendar = Calendar.current
    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 2

    // Build 52 weeks × 7 days grid anchored to today
    private var weeks: [[String?]] {
        let today = Date()
        let weekday = calendar.component(.weekday, from: today) // 1=Sun..7=Sat
        // How many days to roll back to start of grid (52 weeks ago, aligned to Sunday)
        let daysBack = (52 * 7) + (weekday - 1)
        var result: [[String?]] = []
        var week: [String?] = []
        for i in stride(from: daysBack, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -i, to: today)!
            let key = PlaybackHistoryStore.dayKey.string(from: date)
            week.append(key)
            if week.count == 7 {
                result.append(week)
                week = []
            }
        }
        if !week.isEmpty { result.append(week + Array(repeating: nil, count: 7 - week.count)) }
        return result
    }

    private func color(for key: String?) -> Color {
        guard let key, let secs = history.dailySeconds[key], secs > 0 else {
            return Color.white.opacity(0.07)
        }
        let hours = secs / 3600
        switch hours {
        case ..<0.25: return Color.roonAccent.opacity(0.25)
        case ..<1:    return Color.roonAccent.opacity(0.50)
        case ..<3:    return Color.roonAccent.opacity(0.75)
        default:      return Color.roonAccent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, dayKey in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(for: dayKey))
                                    .frame(width: cellSize, height: cellSize)
                                    .onTapGesture {
                                        if let k = dayKey { selectedDay = (selectedDay == k) ? nil : k }
                                    }
                            }
                        }
                    }
                }
            }

            // Selected day detail
            if let day = selectedDay {
                let secs = history.dailySeconds[day] ?? 0
                let mins = Int(secs / 60)
                Text("\(day): \(mins) min listened")
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
                    .transition(.opacity)
            }

            // Legend
            HStack(spacing: 4) {
                Text("Less").font(.roonBody(10)).foregroundColor(.roonTertiary)
                ForEach([0.07, 0.25, 0.50, 0.75, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(opacity < 0.1 ? Color.white.opacity(opacity) : Color.roonAccent.opacity(opacity))
                        .frame(width: cellSize, height: cellSize)
                }
                Text("More").font(.roonBody(10)).foregroundColor(.roonTertiary)
            }
        }
    }
}

// MARK: - Time of day breakdown

private struct TimeOfDayView: View {
    @ObservedObject private var history = PlaybackHistoryStore.shared

    private struct Slot: Identifiable {
        let id: String
        let label: String
        let hours: ClosedRange<Int>
        let icon: String
    }

    private let slots: [Slot] = [
        Slot(id: "morning",   label: "Morning",   hours: 5...11,  icon: "sunrise"),
        Slot(id: "afternoon", label: "Afternoon",  hours: 12...17, icon: "sun.max"),
        Slot(id: "evening",   label: "Evening",    hours: 18...21, icon: "sunset"),
        Slot(id: "night",     label: "Night",      hours: 22...4,  icon: "moon.stars"),
    ]

    private func totalSecs(for slot: Slot) -> Double {
        var total = 0.0
        for h in 0...23 {
            let inRange: Bool
            if slot.hours.lowerBound <= slot.hours.upperBound {
                inRange = slot.hours.contains(h)
            } else {
                inRange = h >= slot.hours.lowerBound || h <= slot.hours.upperBound
            }
            if inRange { total += history.hourBuckets[h] ?? 0 }
        }
        return total
    }

    var body: some View {
        let maxSecs = slots.map { totalSecs(for: $0) }.max() ?? 1
        VStack(spacing: 10) {
            ForEach(slots) { slot in
                let secs = totalSecs(for: slot)
                let fraction = maxSecs > 0 ? secs / maxSecs : 0
                let mins = Int(secs / 60)
                HStack(spacing: 12) {
                    Image(systemName: slot.icon)
                        .font(.system(size: 14))
                        .foregroundColor(.roonAccent)
                        .frame(width: 22)
                    Text(slot.label)
                        .font(.roonBody(13))
                        .foregroundColor(.roonPrimary)
                        .frame(width: 70, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.roonAccent.opacity(0.25))
                        Capsule()
                            .fill(Color.roonAccent)
                            .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                    }
                    .frame(height: 6)
                    Text("\(mins)m")
                        .font(.roonMono(11))
                        .foregroundColor(.roonTertiary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }
}
