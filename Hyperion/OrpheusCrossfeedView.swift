import SwiftUI

// MARK: - Crossfeed Presets

private enum CrossfeedPreset: String, CaseIterable {
    case off     = "Off"
    case mild    = "Mild"
    case natural = "Natural"
    case strong  = "Strong"

    var strength:  Float { switch self { case .off: 0;    case .mild: 0.25; case .natural: 0.45; case .strong: 0.65 } }
    var cutoff:    Float { switch self { case .off: 700;  case .mild: 800;  case .natural: 700;  case .strong: 600  } }
    var delayMs:   Float { switch self { case .off: 0.3;  case .mild: 0.2;  case .natural: 0.3;  case .strong: 0.4  } }
    var bypassed:  Bool  { self == .off }
}

// MARK: - Crossfeed View

struct OrpheusCrossfeedView: View {

    @StateObject private var dsp = OrpheusDSPEngine.shared

    // Computed bindings bridge Float DSP properties to Double-based LabeledSlider.
    private var strengthBinding: Binding<Double> {
        Binding(get: { Double(dsp.crossfeedLevel) },
                set: { dsp.crossfeedLevel = Float($0); dsp.applyCrossfeed() })
    }
    private var cutoffBinding: Binding<Double> {
        Binding(get: { Double(dsp.crossfeedFrequency) },
                set: { dsp.crossfeedFrequency = Float($0); dsp.applyCrossfeed() })
    }
    private var delayBinding: Binding<Double> {
        Binding(get: { Double(dsp.crossfeedDelay) },
                set: { dsp.crossfeedDelay = Float($0); dsp.applyCrossfeed() })
    }

    private var activePreset: CrossfeedPreset? {
        if dsp.crossfeedBypassed { return .off }
        return CrossfeedPreset.allCases.first {
            $0 != .off &&
            abs($0.strength - dsp.crossfeedLevel)   < 0.01 &&
            abs($0.cutoff   - dsp.crossfeedFrequency) < 1 &&
            abs($0.delayMs  - dsp.crossfeedDelay)   < 0.01
        }
    }

    var body: some View {
        List {
            // Headphone route banner
            if !dsp.isHeadphoneOutput {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2")
                            .foregroundColor(.roonSecondary)
                        Text("Crossfeed is active only when headphones are connected. It auto-enables when you plug in or pair headphones.")
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listRowBackground(Color.roonSurface)
            }

            // L/R ear diagram
            Section {
                CrossfeedDiagram(
                    strength: dsp.crossfeedBypassed ? 0 : dsp.crossfeedLevel,
                    isActive: !dsp.crossfeedBypassed && dsp.isHeadphoneOutput
                )
                .frame(height: 80)
                .listRowBackground(Color.roonBase)
                .listRowInsets(EdgeInsets())
            }

            // Presets
            Section("PRESET") {
                HStack(spacing: 8) {
                    ForEach(CrossfeedPreset.allCases, id: \.rawValue) { preset in
                        PresetChip(
                            label: preset.rawValue,
                            isActive: activePreset == preset
                        ) {
                            applyPreset(preset)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.roonSurface)

            // Controls
            Section("CONTROLS") {
                HStack {
                    Toggle("Bypass", isOn: Binding(
                        get: { dsp.crossfeedBypassed },
                        set: { dsp.crossfeedBypassed = $0; dsp.applyCrossfeed() }
                    ))
                    .tint(.roonAccent)
                }

                if !dsp.crossfeedBypassed {
                    LabeledSlider(
                        label: "Strength",
                        value: strengthBinding,
                        range: 0...1,
                        format: "%.0f%%",
                        scale: 100
                    )

                    LabeledSlider(
                        label: "LPF Cutoff",
                        value: cutoffBinding,
                        range: 300...1200,
                        format: "%.0f Hz"
                    )

                    LabeledSlider(
                        label: "ITD Delay",
                        value: delayBinding,
                        range: 0.1...1.0,
                        format: "%.2f ms"
                    )
                }
            }
            .listRowBackground(Color.roonSurface)

            Section("ABOUT") {
                Text("Bauer crossfeed reduces the perceived stereo width on headphones by blending a low-pass filtered, slightly delayed copy of each channel into the opposite side — simulating how speakers in a room are heard by both ears. Higher strength produces a narrower, more speaker-like soundstage. Active only with wired or Bluetooth headphones.")
                    .font(.roonBody(12))
                    .foregroundColor(.roonTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Color.roonSurface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .bottomOverlayAwareScroll()
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle("Crossfeed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func applyPreset(_ preset: CrossfeedPreset) {
        Haptics.light()
        dsp.crossfeedBypassed  = preset.bypassed
        dsp.crossfeedLevel     = preset.strength
        dsp.crossfeedFrequency = preset.cutoff
        dsp.crossfeedDelay     = preset.delayMs
        dsp.applyCrossfeed()
    }
}

// MARK: - L/R Ear Diagram

private struct CrossfeedDiagram: View {
    let strength: Float
    let isActive: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let midX = w / 2
            let earRadius: CGFloat = 18
            let speakerY: CGFloat  = h * 0.25
            let earY: CGFloat      = h * 0.75

            // Speaker labels
            draw(ctx: ctx, text: "L", at: CGPoint(x: w * 0.2,  y: speakerY), size: size)
            draw(ctx: ctx, text: "R", at: CGPoint(x: w * 0.8,  y: speakerY), size: size)

            // Ear circles
            let earLCenter = CGPoint(x: w * 0.3, y: earY)
            let earRCenter = CGPoint(x: w * 0.7, y: earY)
            ctx.stroke(Path(ellipseIn: CGRect(x: earLCenter.x - earRadius, y: earLCenter.y - earRadius,
                                              width: earRadius * 2, height: earRadius * 2)),
                       with: .color(.roonAccent.opacity(0.8)), lineWidth: 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: earRCenter.x - earRadius, y: earRCenter.y - earRadius,
                                              width: earRadius * 2, height: earRadius * 2)),
                       with: .color(.roonAccent.opacity(0.8)), lineWidth: 2)
            draw(ctx: ctx, text: "L", at: earLCenter, size: size, small: true)
            draw(ctx: ctx, text: "R", at: earRCenter, size: size, small: true)

            // Direct signal lines (solid)
            drawArrow(ctx: ctx, from: CGPoint(x: w * 0.2, y: speakerY + 8),
                      to: earLCenter, color: Color.roonPrimary, opacity: 0.6, lineWidth: 1.5)
            drawArrow(ctx: ctx, from: CGPoint(x: w * 0.8, y: speakerY + 8),
                      to: earRCenter, color: Color.roonPrimary, opacity: 0.6, lineWidth: 1.5)

            // Cross-feed lines (dashed, opacity reflects strength)
            if isActive && strength > 0.01 {
                let crossOpacity = Double(strength) * 0.7
                drawDashedArrow(ctx: ctx,
                                from: CGPoint(x: w * 0.2, y: speakerY + 8),
                                via:  CGPoint(x: midX, y: (speakerY + earY) / 2),
                                to:   earRCenter,
                                color: Color.roonAccent, opacity: crossOpacity)
                drawDashedArrow(ctx: ctx,
                                from: CGPoint(x: w * 0.8, y: speakerY + 8),
                                via:  CGPoint(x: midX, y: (speakerY + earY) / 2),
                                to:   earLCenter,
                                color: Color.roonAccent, opacity: crossOpacity)
            }
        }
    }

    private func draw(ctx: GraphicsContext, text: String, at pt: CGPoint, size: CGSize, small: Bool = false) {
        var tc = ctx
        tc.draw(Text(text).font(.system(size: small ? 11 : 12, weight: .semibold))
                    .foregroundColor(Color.roonSecondary),
                at: pt)
    }

    private func drawArrow(ctx: GraphicsContext, from: CGPoint, to: CGPoint,
                           color: Color, opacity: Double, lineWidth: CGFloat) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        ctx.stroke(path, with: .color(color.opacity(opacity)), lineWidth: lineWidth)
    }

    private func drawDashedArrow(ctx: GraphicsContext, from: CGPoint, via: CGPoint,
                                 to: CGPoint, color: Color, opacity: Double) {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: via)
        ctx.stroke(path, with: .color(color.opacity(opacity)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }
}

// MARK: - Preset Chip

private struct PresetChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.roonBody(13, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .black : .roonPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isActive ? Color.roonAccent : Color.roonElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

