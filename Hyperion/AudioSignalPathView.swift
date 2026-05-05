import SwiftUI

// MARK: - Quality Badge

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

// MARK: - Pulsing ring animation helper

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

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    Divider().background(Color.roonBorder)

                    VStack(spacing: 0) {
                        ForEach(Array(path.steps.enumerated()), id: \.element.id) { index, step in
                            AudioPathStepRow(step: step, isLast: index == path.steps.count - 1)
                        }
                    }
                    .padding(.vertical, 18)

                    if !path.whyNotBitPerfect.isEmpty {
                        whyNotBitPerfectSection
                    }

                    footer

                    #if DEBUG
                    if path.diagnostics.hasContent {
                        diagnosticsSection
                    }
                    #endif
                }
            }
            .scrollContentBackground(.hidden)
            .bottomOverlayAwareScroll()
            .background(Color.roonBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.roonTertiary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(path.worstStatus.tintColor)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(path.badgeLabel)
                        .font(.roonTitle(24, weight: .bold))
                        .foregroundColor(.roonPrimary)
                    Text(path.bitPerfectExplanation)
                        .font(.roonBody(12, weight: .medium))
                        .foregroundColor(.roonSecondary)
                }
            }

            Text("Hyperion shows only steps backed by LMS/player/track/Orpheus data. Unknown means the app could not verify that part of the chain.")
                .font(.roonBody(12))
                .foregroundColor(.roonTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(Color.roonSurface)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var whyNotBitPerfectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why bit-perfect is not claimed")
                .font(.roonBody(14, weight: .semibold))
                .foregroundColor(.roonPrimary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(path.whyNotBitPerfect, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.roonTertiary)
                            .padding(.top, 2)
                        Text(reason)
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.roonSurface.opacity(0.72))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(Color.roonBorder)
            Text("No “bit-perfect,” “lossless output,” “hi-res,” or “transcoded” claim is made unless the path has the data to support it. Missing LMS fields are shown as unknown instead of guessed.")
                .font(.roonBody(11))
                .foregroundColor(.roonTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    #if DEBUG
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signal-path diagnostics")
                .font(.roonBody(14, weight: .semibold))
                .foregroundColor(.roonPrimary)

            DiagnosticsList(title: "Fields used", values: path.diagnostics.usedFields)
            DiagnosticsList(title: "Missing / unverified fields", values: path.diagnostics.missingFields)
            DiagnosticsDictionary(title: "Raw LMS/track fields", values: path.diagnostics.rawTrackFields)
            DiagnosticsDictionary(title: "Raw player/status fields", values: path.diagnostics.rawStatusFields)
            DiagnosticsList(title: "Notes", values: path.diagnostics.notes)
        }
        .padding(16)
        .background(Color.roonSurface.opacity(0.55))
        .cornerRadius(12)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }
    #endif
}

// MARK: - Step Row

struct AudioPathStepRow: View {
    let step: AudioPathStep
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(step.status.tintColor.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: step.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(step.status.tintColor)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(step.title)
                            .font(.roonBody(14, weight: .semibold))
                            .foregroundColor(.roonPrimary)

                        Text(step.confidence.label)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.roonTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.roonTertiary.opacity(0.12))
                            .cornerRadius(4)
                    }

                    Text(step.subtitle)
                        .font(.roonBody(12, weight: .regular))
                        .foregroundColor(.roonSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let technicalValue = step.technicalValue, !technicalValue.isEmpty, technicalValue != step.subtitle {
                        Text(technicalValue)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.roonTertiary)
                            .lineLimit(2)
                    }

                    if !step.explanation.isEmpty {
                        Text(step.explanation)
                            .font(.roonBody(11))
                            .foregroundColor(.roonTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Source: \(step.sourceOfTruth)")
                        .font(.roonBody(10, weight: .medium))
                        .foregroundColor(.roonTertiary.opacity(0.9))
                }

                Spacer(minLength: 8)

                Text(step.statusLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(step.status.tintColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(step.status.tintColor.opacity(0.15))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if !isLast {
                Rectangle()
                    .fill(Color.roonBorder)
                    .frame(width: 2, height: 20)
                    .padding(.leading, 42)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title): \(step.subtitle)")
        .accessibilityValue(step.statusLabel)
    }
}

#if DEBUG
private struct DiagnosticsList: View {
    let title: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text("• \(value)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(title)
                    .font(.roonBody(12, weight: .semibold))
                    .foregroundColor(.roonPrimary)
            }
            .tint(.roonSecondary)
        }
    }
}

private struct DiagnosticsDictionary: View {
    let title: String
    let values: [String: String]

    var body: some View {
        if !values.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(values.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(values[key] ?? "")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(title)
                    .font(.roonBody(12, weight: .semibold))
                    .foregroundColor(.roonPrimary)
            }
            .tint(.roonSecondary)
        }
    }
}
#endif

// MARK: - Preview

#Preview {
    AudioSignalPathView(path: .mockPath)
}

#Preview("Badge") {
    HStack(spacing: 16) {
        AudioQualityBadge(
            path: .mockPath,
            onTap: {}
        )
        Spacer()
    }
    .padding()
    .background(Color.roonBase)
}
