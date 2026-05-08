import SwiftUI

// MARK: - Quality Badge (used by NowPlayingView header bar)

struct AudioQualityBadge: View {
    let path: AudioSignalPath
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(path.worstStatus.tintColor)
                        .frame(width: 10, height: 10)
                    if path.isVerifiedBitPerfect {
                        PulsingRingView(color: path.worstStatus.tintColor)
                    }
                }
                Text(path.badgeLabel)
                    .font(.roonBody(12, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.roonTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.roonSurface.opacity(0.9))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio quality: \(path.badgeLabel)")
        .accessibilityHint("Double tap to view signal path details")
    }
}

private struct PulsingRingView: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.4), lineWidth: 2)
            .frame(width: 10, height: 10)
            .scaleEffect(isPulsing ? 1.6 : 1.0)
            .opacity(isPulsing ? 0.0 : 0.6)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Signal Path Modal

struct AudioSignalPathView: View {
    let path: AudioSignalPath
    @Environment(\.dismiss) private var dismiss
    @State private var expandedIndex: Int? = nil

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    pathHeader
                    timeline
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.roonTertiary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    // MARK: - Header

    private var pathHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(path.worstStatus.tintColor)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(path.badgeLabel)
                    .font(.roonTitle(22, weight: .bold))
                    .foregroundColor(.roonPrimary)
                Text(path.isVerifiedBitPerfect
                     ? "Full path verified"
                     : "Signal path — tap a stage for detail")
                    .font(.roonBody(12))
                    .foregroundColor(.roonSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Timeline

    private var timeline: some View {
        let stages = buildStages()
        return VStack(spacing: 0) {
            ForEach(stages.indices, id: \.self) { i in
                TimelineStageRow(
                    stage: stages[i],
                    isFirst: i == 0,
                    isLast: i == stages.count - 1,
                    isExpanded: expandedIndex == i
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        expandedIndex = (expandedIndex == i) ? nil : i
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 48)
    }

    // MARK: - Stage model

    struct StageData {
        let id: Int
        let name: String
        let icon: String
        let dataLine: String
        let status: QualityStatus
        let details: [(label: String, value: String)]
    }

    // MARK: - Map 8-10 AudioPathSteps → 5 StageData

    private func buildStages() -> [StageData] {
        let byID = Dictionary(path.steps.map { ($0.id, $0) }, uniquingKeysWith: { $1 })

        // Stage 1 — Source
        let src = byID["source"]
        let srcLine = cleanLine(src?.technicalValue) ?? cleanLine(src?.subtitle) ?? "Unknown"
        let srcDetails = buildDetails(step: src, extras: [])

        // Stage 2 — Decode
        let dec = byID["decode"]
        let decLine: String = {
            // technicalValue is the decoded format or stream URL; prefer short format string
            if let tv = dec?.technicalValue, !tv.isEmpty, !tv.hasPrefix("/"), !tv.hasPrefix("…") {
                return tv
            }
            return dec?.subtitle ?? "AVPlayer"
        }()
        let decDetails = buildDetails(step: dec, extras: [])

        // Stage 3 — LMS Processing
        let lms = byID["lms-processing"]
        let lmsLine = cleanLine(lms?.subtitle) ?? "Unknown"
        let lmsDetails = buildDetails(step: lms, extras: [])

        // Stage 4 — ReplayGain / Volume (merge two steps)
        let rg  = byID["replaygain"]
        let vol = byID["volume"]
        let rgPart  = rg?.technicalValue  ?? "RG off"
        let volPart = vol?.technicalValue.map { "Vol \($0)" } ?? "Vol ?"
        let volStatus: QualityStatus = [rg?.status ?? .unknown, vol?.status ?? .unknown]
            .max(by: { $0.severity < $1.severity }) ?? .unknown
        var volDetails: [(String, String)] = []
        if let tv = rg?.technicalValue  { volDetails.append(("ReplayGain", tv)) }
        else                            { volDetails.append(("ReplayGain", "Not reported")) }
        if let tv = vol?.technicalValue { volDetails.append(("App volume", tv)) }
        if let src = vol?.sourceOfTruth { volDetails.append(("Source", src)) }

        // Stage 5 — Output
        let out = byID["output"]
        let outLine = cleanLine(out?.technicalValue) ?? cleanLine(out?.subtitle) ?? "Unknown"
        var outDetails = buildDetails(step: out, extras: [])
        if !path.whyNotBitPerfect.isEmpty {
            outDetails.append(("", ""))  // divider
            outDetails.append(("Not claimed", path.whyNotBitPerfect.joined(separator: "\n")))
        }

        return [
            StageData(id: 0, name: "Source",             icon: "opticaldisc",    dataLine: srcLine,  status: src?.status ?? .unknown, details: srcDetails),
            StageData(id: 1, name: "Decode",              icon: "waveform",       dataLine: decLine,  status: dec?.status ?? .unknown, details: decDetails),
            StageData(id: 2, name: "LMS Processing",      icon: "network",        dataLine: lmsLine,  status: lms?.status ?? .unknown, details: lmsDetails),
            StageData(id: 3, name: "ReplayGain / Volume", icon: "dial.medium",    dataLine: "\(rgPart) · \(volPart)", status: volStatus, details: volDetails),
            StageData(id: 4, name: "Output",              icon: "headphones",     dataLine: outLine,  status: out?.status ?? .unknown, details: outDetails),
        ]
    }

    private func cleanLine(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Strip raw URL paths that start with "/" or "…" — not useful as a collapsed data line
        if s.hasPrefix("/") || s.hasPrefix("…") { return nil }
        return s
    }

    private func buildDetails(step: AudioPathStep?, extras: [(String, String)]) -> [(String, String)] {
        guard let step else { return extras }
        var d: [(String, String)] = []
        let sub = step.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sub.isEmpty { d.append(("Detail", sub)) }
        if let tv = step.technicalValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tv.isEmpty, tv != sub, !tv.hasPrefix("/"), !tv.hasPrefix("…") {
            d.append(("Technical", tv))
        }
        if !step.usedFields.isEmpty { d.append(("Fields used", step.usedFields.joined(separator: ", "))) }
        if !step.missingFields.isEmpty { d.append(("Not reported", step.missingFields.joined(separator: ", "))) }
        let sot = step.sourceOfTruth.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sot.isEmpty, sot != "Not reported" { d.append(("Source", sot)) }
        return d + extras
    }
}

// MARK: - Timeline Stage Row

private struct TimelineStageRow: View {
    let stage: AudioSignalPathView.StageData
    let isFirst: Bool
    let isLast: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    private let circleSize: CGFloat  = 28
    private let lineWidth:  CGFloat  = 2
    private let colWidth:   CGFloat  = 36

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                timelineColumn
                contentColumn
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stage.name): \(stage.dataLine)")
        .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand details")
    }

    // Left column — circle icon + continuous vertical connector line

    private var timelineColumn: some View {
        VStack(spacing: 0) {
            // Top half-connector (drawn above circle, except on first stage)
            if isFirst {
                Color.clear.frame(width: lineWidth, height: 14)
            } else {
                Color.roonBorder.opacity(0.55).frame(width: lineWidth, height: 14)
            }

            // Stage circle
            ZStack {
                Circle()
                    .fill(stage.status.tintColor.opacity(0.15))
                    .frame(width: circleSize, height: circleSize)
                Image(systemName: stage.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(stage.status.tintColor)
            }

            // Bottom connector fills remaining row height (drives continuous line)
            if !isLast {
                Color.roonBorder.opacity(0.55).frame(width: lineWidth).frame(maxHeight: .infinity)
            }
        }
        .frame(width: colWidth)
    }

    // Right column — name + data line + optional expanded detail

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header — always visible
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(stage.name)
                            .font(.roonBody(13, weight: .semibold))
                            .foregroundColor(.roonPrimary)
                        Circle()
                            .fill(stage.status.tintColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(stage.dataLine)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.roonTertiary)
            }
            .padding(.top, 8)
            .padding(.bottom, isExpanded ? 10 : 14)

            // Expanded detail block
            if isExpanded, !stage.details.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(stage.details.indices, id: \.self) { i in
                        let row = stage.details[i]
                        if row.label.isEmpty && row.value.isEmpty {
                            Color.roonBorder.frame(height: 0.5).padding(.vertical, 6)
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                Text(row.label)
                                    .font(.roonBody(11, weight: .medium))
                                    .foregroundColor(.roonTertiary)
                                    .frame(width: 88, alignment: .trailing)
                                Text(row.value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.roonSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.roonSurface.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 14)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AudioSignalPathView(path: .mockPath)
        .preferredColorScheme(.dark)
}

#Preview("Badge") {
    HStack(spacing: 16) {
        AudioQualityBadge(path: .mockPath, onTap: {})
        Spacer()
    }
    .padding()
    .background(Color.roonBase)
}
