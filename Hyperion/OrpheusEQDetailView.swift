import SwiftUI

struct OrpheusEQDetailView: View {

    let isHeadphone: Bool

    @StateObject private var dsp = OrpheusDSPEngine.shared
    @State private var selectedBandID: UUID? = nil

    private var title: String { isHeadphone ? "Headphone EQ" : "Parametric EQ" }

    private var bands: Binding<[OrpheusEQBand]> {
        isHeadphone ? $dsp.headphoneEQBands : $dsp.mainEQBands
    }

    private var bypassed: Binding<Bool> {
        isHeadphone
            ? Binding(get: { dsp.headphoneEQBypassed }, set: { dsp.headphoneEQBypassed = $0; dsp.applyHeadphoneEQ() })
            : Binding(get: { dsp.mainEQBypassed },      set: { dsp.mainEQBypassed = $0;      dsp.applyMainEQ()      })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Frequency response curve
                EQFrequencyResponseView(
                    bands: isHeadphone ? dsp.headphoneEQBands : dsp.mainEQBands,
                    bypassed: isHeadphone ? dsp.headphoneEQBypassed : dsp.mainEQBypassed,
                    selectedBandID: $selectedBandID
                ) { bandID, newGain in
                    updateGain(bandID: bandID, gain: newGain)
                } onFrequencyDrag: { bandID, newFreq in
                    updateFrequency(bandID: bandID, frequency: newFreq)
                }
                .frame(height: 200)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Bypass toggle
                HStack {
                    Text("Bypass")
                        .font(.roonBody(14))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    Toggle("", isOn: bypassed)
                        .labelsHidden()
                        .tint(.roonAccent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.roonSurface)

                Divider().background(Color.roonBorder)

                // Band list
                ForEach(bands) { $band in
                    EQBandRow(
                        band: $band,
                        isSelected: selectedBandID == band.id,
                        onTap: {
                            selectedBandID = selectedBandID == band.id ? nil : band.id
                        },
                        onChange: applyEQ
                    )
                    Divider().background(Color.roonBorder).padding(.leading, 16)
                }

                // Add / reset buttons
                HStack(spacing: 12) {
                    Button {
                        addBand()
                    } label: {
                        Label("Add Band", systemImage: "plus")
                            .font(.roonBody(13, weight: .semibold))
                            .foregroundColor(.roonAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(bands.wrappedValue.count >= 10)

                    Spacer()

                    Button {
                        resetBands()
                    } label: {
                        Text("Reset")
                            .font(.roonBody(13))
                            .foregroundColor(.roonTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.roonBase.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func updateGain(bandID: UUID, gain: Float) {
        if isHeadphone {
            if let idx = dsp.headphoneEQBands.firstIndex(where: { $0.id == bandID }) {
                dsp.headphoneEQBands[idx].gain = max(-12, min(12, gain))
            }
        } else {
            if let idx = dsp.mainEQBands.firstIndex(where: { $0.id == bandID }) {
                dsp.mainEQBands[idx].gain = max(-12, min(12, gain))
            }
        }
        applyEQ()
    }

    private func updateFrequency(bandID: UUID, frequency: Float) {
        if isHeadphone {
            if let idx = dsp.headphoneEQBands.firstIndex(where: { $0.id == bandID }) {
                dsp.headphoneEQBands[idx].frequency = max(20, min(20000, frequency))
            }
        } else {
            if let idx = dsp.mainEQBands.firstIndex(where: { $0.id == bandID }) {
                dsp.mainEQBands[idx].frequency = max(20, min(20000, frequency))
            }
        }
        applyEQ()
    }

    private func applyEQ() {
        if isHeadphone { dsp.applyHeadphoneEQ() } else { dsp.applyMainEQ() }
    }

    private func addBand() {
        let newBand = OrpheusEQBand(filterType: .peak, frequency: 1000, gain: 0, bandwidth: 1, isActive: true)
        if isHeadphone { dsp.headphoneEQBands.append(newBand) }
        else            { dsp.mainEQBands.append(newBand) }
        selectedBandID = newBand.id
        applyEQ()
    }

    private func resetBands() {
        let defaults = OrpheusDSPEngine.defaultEQBands()
        if isHeadphone { dsp.headphoneEQBands = defaults }
        else            { dsp.mainEQBands      = defaults }
        selectedBandID = nil
        applyEQ()
    }
}

// MARK: - Frequency Response Canvas

struct EQFrequencyResponseView: View {

    let bands: [OrpheusEQBand]
    let bypassed: Bool
    @Binding var selectedBandID: UUID?
    let onGainDrag: (UUID, Float) -> Void
    let onFrequencyDrag: (UUID, Float) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Canvas { ctx, size in
                drawGrid(ctx: ctx, size: size)
                drawCurve(ctx: ctx, size: size)
            }
            .background(Color.roonElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                ZStack {
                    ForEach(bands) { band in
                        let x = freqToX(band.frequency, width: w)
                        let y = gainToY(band.gain, height: h)
                        Circle()
                            .fill(selectedBandID == band.id ? Color.roonAccent : Color.white)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().stroke(Color.roonAccent, lineWidth: selectedBandID == band.id ? 0 : 1.5)
                            )
                            .position(x: x, y: y)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { val in
                                        selectedBandID = band.id
                                        let newFreq = xToFreq(Float(val.location.x), width: Float(w))
                                        let newGain = yToGain(Float(val.location.y), height: Float(h))
                                        onFrequencyDrag(band.id, newFreq)
                                        onGainDrag(band.id, newGain)
                                    }
                            )
                    }
                }
            )
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        let gridColor = Color.white.opacity(0.06)
        // Frequency gridlines at decade/mid positions
        let gridFreqs: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        for f in gridFreqs {
            let x = CGFloat(freqToX(f, width: Float(size.width)))
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
        // Gain gridlines at ±6, ±12 dB
        let gainDBs: [Float] = [-12, -6, 0, 6, 12]
        for g in gainDBs {
            let y = CGFloat(gainToY(g, height: Float(size.height)))
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(path, with: .color(g == 0 ? Color.white.opacity(0.14) : gridColor), lineWidth: 0.5)
        }
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize) {
        let steps = Int(size.width)
        guard steps > 1 else { return }

        var path = Path()
        for i in 0..<steps {
            let x = CGFloat(i)
            let freq = xToFreq(Float(x), width: Float(size.width))
            let db = OrpheusDSPEngine.responseDB(at: Double(freq), bands: bands, bypassed: bypassed)
            let y = CGFloat(gainToY(Float(db), height: Float(size.height)))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else       { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(bypassed ? Color.roonTertiary : Color.white), lineWidth: 2)
    }

    // Freq ↔ X: logarithmic 20–20000 Hz
    private func freqToX(_ freq: Float, width: Float) -> CGFloat {
        let logMin = log10(20.0 as Float)
        let logMax = log10(20000.0 as Float)
        let clamped = max(20, min(20000, freq))
        return CGFloat((log10(clamped) - logMin) / (logMax - logMin) * width)
    }

    private func xToFreq(_ x: Float, width: Float) -> Float {
        let logMin = log10(20.0 as Float)
        let logMax = log10(20000.0 as Float)
        let t = max(0, min(1, x / width))
        return pow(10.0, logMin + t * (logMax - logMin))
    }

    // Gain ↔ Y: −15 dB (bottom) to +15 dB (top)
    private func gainToY(_ gainDB: Float, height: Float) -> CGFloat {
        let t = (gainDB - 15) / (-15 - 15)   // 1 at top, 0 at bottom
        return CGFloat(max(0, min(height, t * height)))
    }

    private func yToGain(_ y: Float, height: Float) -> Float {
        let t = max(0, min(1, y / height))
        return 15.0 - t * 30.0   // +15 at y=0, −15 at y=height
    }
}

// MARK: - EQ Band Row

struct EQBandRow: View {

    @Binding var band: OrpheusEQBand
    let isSelected: Bool
    let onTap: () -> Void
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: $band.isActive)
                    .labelsHidden()
                    .tint(.roonAccent)
                    .onChange(of: band.isActive) { _, _ in onChange() }

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f Hz", band.frequency))
                        .font(.roonMono(14))
                        .foregroundColor(.roonPrimary)
                    Text(band.filterType.rawValue)
                        .font(.roonBody(11))
                        .foregroundColor(.roonTertiary)
                }

                Spacer()

                Text(String(format: "%+.1f dB", band.gain))
                    .font(.roonMono(13))
                    .foregroundColor(band.gain > 0 ? .roonAccent : (band.gain < 0 ? Color(hex: "#5b9ccc") : .roonTertiary))

                Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(.roonTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            if isSelected {
                EQBandEditor(band: $band, onChange: onChange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .background(isSelected ? Color.roonSurface.opacity(0.6) : Color.clear)
    }
}

// MARK: - EQ Band Editor

struct EQBandEditor: View {

    @Binding var band: OrpheusEQBand
    let onChange: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Filter type
            Picker("Type", selection: $band.filterType) {
                ForEach(EQFilterType.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: band.filterType) { _, _ in onChange() }

            // Frequency
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Frequency")
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                    Spacer()
                    Text(String(format: "%.0f Hz", band.frequency))
                        .font(.roonMono(12))
                        .foregroundColor(.roonPrimary)
                }
                Slider(value: Binding(
                    get: { Double(band.frequency) },
                    set: { band.frequency = Float($0); onChange() }
                ), in: 20...20000)
                .tint(.roonAccent)
            }

            // Gain (skip for LP/HP)
            if band.filterType != .lowPass && band.filterType != .highPass {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gain")
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                        Spacer()
                        Text(String(format: "%+.1f dB", band.gain))
                            .font(.roonMono(12))
                            .foregroundColor(.roonPrimary)
                    }
                    Slider(value: Binding(
                        get: { Double(band.gain) },
                        set: { band.gain = Float($0); onChange() }
                    ), in: -12...12)
                    .tint(.roonAccent)
                }
            }

            // Q / Bandwidth
            if band.filterType == .peak {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Q")
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                        Spacer()
                        Text(String(format: "%.2f", band.bandwidth))
                            .font(.roonMono(12))
                            .foregroundColor(.roonPrimary)
                    }
                    Slider(value: Binding(
                        get: { Double(band.bandwidth) },
                        set: { band.bandwidth = Float($0); onChange() }
                    ), in: 0.1...10)
                    .tint(.roonAccent)
                }
            }
        }
    }
}
