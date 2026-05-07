import SwiftUI

/// Reusable labelled slider used across all Orpheus detail screens.
struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1.0  // multiplied into the displayed value only (e.g. 100 for 0–1 → 0–100%)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.roonBody(13))
                    .foregroundColor(.roonSecondary)
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.roonMono(13))
                    .foregroundColor(.roonPrimary)
            }
            Slider(value: $value, in: range)
                .tint(.roonAccent)
        }
    }
}
