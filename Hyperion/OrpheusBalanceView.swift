import SwiftUI

struct OrpheusBalanceView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared

    var body: some View {
        List {
            Section {
                Toggle("Bypass", isOn: Binding(
                    get: { dsp.balanceBypassed },
                    set: { dsp.balanceBypassed = $0; dsp.applyBalance() }
                ))
                .tint(.roonAccent)

                Toggle("Mono", isOn: Binding(
                    get: { dsp.balanceMono },
                    set: { dsp.balanceMono = $0; dsp.applyBalance() }
                ))
                .tint(.roonAccent)
            }

            Section("Balance") {
                LabeledSlider(
                    label: "Left Channel",
                    value: Binding(
                        get: { Double(dsp.balanceLeft) },
                        set: { dsp.balanceLeft = Float($0); dsp.applyBalance() }
                    ),
                    range: -6...6,
                    format: "%+.1f dB"
                )

                LabeledSlider(
                    label: "Right Channel",
                    value: Binding(
                        get: { Double(dsp.balanceRight) },
                        set: { dsp.balanceRight = Float($0); dsp.applyBalance() }
                    ),
                    range: -6...6,
                    format: "%+.1f dB"
                )

                Button("Center Balance") {
                    dsp.balanceLeft  = 0
                    dsp.balanceRight = 0
                    dsp.applyBalance()
                }
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.roonAccent)
            }

            Section {
                BalanceMeterView(left: dsp.balanceLeft, right: dsp.balanceRight)
                    .frame(height: 48)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Balance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct BalanceMeterView: View {
    let left: Float
    let right: Float

    private func barWidth(_ gain: Float, total: CGFloat) -> CGFloat {
        let norm = (Double(gain) + 6.0) / 12.0
        return CGFloat(max(0, min(1, norm))) * total
    }

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            HStack(spacing: 4) {
                // Left bar
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.roonElevated)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.roonAccent.opacity(0.6))
                        .frame(width: barWidth(left, total: half - 2))
                }
                .frame(width: half - 2)

                // Center marker
                Rectangle()
                    .fill(Color.roonBorder)
                    .frame(width: 1)

                // Right bar
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.roonElevated)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.roonAccent.opacity(0.6))
                        .frame(width: barWidth(right, total: half - 2))
                }
                .frame(width: half - 2)
            }
        }
    }
}
