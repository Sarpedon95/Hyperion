import SwiftUI

// MARK: - Quality Badge

struct AudioQualityBadge: View {
    let path: AudioSignalPath
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Status indicator circle with pulsing animation for lossless
                ZStack {
                    Circle()
                        .fill(path.worstStatus.tintColor)
                        .frame(width: 10, height: 10)

                    if path.worstStatus == .lossless {
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

/// Separate view so the @State is stable across parent re-renders.
/// The old code used `value: UUID()` which created a new UUID on every
/// SwiftUI layout pass, causing the animation to restart constantly.
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
                    // Header with quality summary
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(path.worstStatus.tintColor)
                                .frame(width: 14, height: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(path.badgeLabel)
                                    .font(.roonTitle(24, weight: .bold))
                                    .foregroundColor(.roonPrimary)
                                Text("Audio Signal Path")
                                    .font(.roonBody(12))
                                    .foregroundColor(.roonTertiary)
                            }
                        }
                    }
                    .padding(20)
                    .background(Color.roonSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                        .background(Color.roonBorder)

                    // Signal path steps
                    VStack(spacing: 0) {
                        ForEach(Array(path.steps.enumerated()), id: \.element.id) { index, step in
                            AudioPathStepRow(step: step, isLast: index == path.steps.count - 1)
                        }
                    }
                    .padding(.vertical, 20)

                    // Footer info
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .background(Color.roonBorder)

                        Text("Real-time data from playback engine")
                            .font(.roonBody(11))
                            .foregroundColor(.roonTertiary)
                            .padding(12)
                    }
                }
            }
            .scrollContentBackground(.hidden)
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
}

// MARK: - Step Row

struct AudioPathStepRow: View {
    let step: AudioPathStep
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Row content
            HStack(alignment: .center, spacing: 14) {
                // Circle icon with status color
                ZStack {
                    Circle()
                        .fill(step.status.tintColor.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: step.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(step.status.tintColor)
                }

                // Content - left side
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.roonBody(14, weight: .semibold))
                        .foregroundColor(.roonPrimary)

                    Text(step.subtitle)
                        .font(.roonBody(12, weight: .regular))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(2)
                }

                Spacer()

                // Status badge - right side
                VStack(alignment: .trailing, spacing: 2) {
                    Text(step.status.displayLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(step.status.tintColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(step.status.tintColor.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // Vertical line connector to the next step. Rendered only between
            // steps (not after the last one). Each step provides its OWN
            // connector below it — do NOT also render an "above" connector on
            // the next step, or you get a doubled line between every pair.
            if !isLast {
                Rectangle()
                    .fill(Color.roonBorder)
                    .frame(width: 2, height: 20)
                    .padding(.leading, 42)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title): \(step.subtitle)")
        .accessibilityValue(step.status.displayLabel)
    }
}

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
