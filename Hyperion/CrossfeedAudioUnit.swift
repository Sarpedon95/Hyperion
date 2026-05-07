import AVFoundation
import AudioToolbox

// MARK: - DSP Kernel

// Holds all mutable DSP state accessed from the audio render thread.
// Parameters (strength, lpfAlpha, delaySamples, bypassed) are written from the
// main thread and read from the audio thread.  On ARM64 each is a single-word
// load/store, so no torn reads occur in practice.
final class CrossfeedKernel {

    var strength:    Float = 0.45   // cross-mix factor, 0…1
    var lpfAlpha:    Float = 0.905  // 1-pole IIR coeff; recomputed from cutoff+SR
    var delaySamples: Int = 13      // ITD delay (~0.3 ms @ 44100)
    var bypassed:    Bool = false

    private let maxDelay = 512
    var bufL: [Float]
    var bufR: [Float]
    var writeIdx: Int  = 0
    var lpfStateL: Float = 0
    var lpfStateR: Float = 0

    init() {
        bufL = Array(repeating: 0, count: 512)
        bufR = Array(repeating: 0, count: 512)
    }

    func reset() {
        bufL      = Array(repeating: 0, count: maxDelay)
        bufR      = Array(repeating: 0, count: maxDelay)
        writeIdx  = 0
        lpfStateL = 0
        lpfStateR = 0
    }

    // Called on the audio render thread — must be real-time safe (no allocations, no locks).
    func process(ptrL: UnsafeMutablePointer<Float>,
                 ptrR: UnsafeMutablePointer<Float>,
                 count: Int) {
        guard !bypassed else { return }

        let alpha  = lpfAlpha
        let str    = strength
        let delay  = delaySamples
        let maxBuf = maxDelay

        var lpfL = lpfStateL
        var lpfR = lpfStateR
        var wIdx = writeIdx

        for i in 0..<count {
            let inL = ptrL[i]
            let inR = ptrR[i]

            // 1-pole IIR low-pass on the cross-channel signals
            lpfL = alpha * lpfL + (1 - alpha) * inL
            lpfR = alpha * lpfR + (1 - alpha) * inR

            // Write filtered signal to circular delay buffers
            bufL[wIdx] = lpfL
            bufR[wIdx] = lpfR
            wIdx = (wIdx + 1) % maxBuf

            // Read cross-channel signal with ITD delay
            let rIdx = (wIdx - delay + maxBuf) % maxBuf
            let crossToL = bufR[rIdx]   // delayed LPF of R → add to L
            let crossToR = bufL[rIdx]   // delayed LPF of L → add to R

            // Bauer mix
            ptrL[i] = inL + str * crossToL
            ptrR[i] = inR + str * crossToR
        }

        lpfStateL = lpfL
        lpfStateR = lpfR
        writeIdx  = wIdx
    }
}

// MARK: - AUAudioUnit subclass

final class CrossfeedAudioUnit: AUAudioUnit {

    // MARK: Component registration

    static let componentDescription = AudioComponentDescription(
        componentType:        kAudioUnitType_Effect,
        componentSubType:     0x48797052,   // "HypR"
        componentManufacturer: 0x48797072,  // "Hypr"
        componentFlags:       AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask:   0
    )

    static func register() {
        AUAudioUnit.registerSubclass(
            CrossfeedAudioUnit.self,
            as: componentDescription,
            name: "Hyperion Crossfeed",
            version: 1
        )
    }

    // MARK: Parameters (written main thread, read render thread)

    var strength: Float = 0.45 {
        didSet { kernel.strength = strength }
    }

    var cutoffHz: Float = 700 {
        didSet { recomputeCoefficients() }
    }

    var delayMs: Float = 0.3 {
        didSet { recomputeDelaySamples() }
    }

    var isBypassed: Bool = false {
        didSet { kernel.bypassed = isBypassed }
    }

    // MARK: DSP Kernel

    let kernel = CrossfeedKernel()

    // MARK: Bus arrays

    private var _inputBusArray:  AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    override var inputBusses:  AUAudioUnitBusArray { _inputBusArray  }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    // MARK: Init

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        let stereo = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let inBus  = try AUAudioUnitBus(format: stereo)
        inBus.maximumChannelCount = 8
        let outBus = try AUAudioUnitBus(format: stereo)

        _inputBusArray  = AUAudioUnitBusArray(audioUnit: self, busType: .input,  busses: [inBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        maximumFramesToRender = 4096
    }

    // MARK: Resource allocation

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        recomputeCoefficients()
        recomputeDelaySamples()
        kernel.reset()
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        kernel.reset()
    }

    // MARK: Coefficient helpers

    private var currentSampleRate: Double {
        outputBusses[0].format.sampleRate
    }

    private func recomputeCoefficients() {
        let sr = currentSampleRate > 0 ? currentSampleRate : 44100
        kernel.lpfAlpha = Float(exp(-2 * Double.pi * Double(cutoffHz) / sr))
    }

    private func recomputeDelaySamples() {
        let sr = currentSampleRate > 0 ? currentSampleRate : 44100
        let samples = Int(Double(delayMs) * 0.001 * sr)
        kernel.delaySamples = max(1, min(511, samples))
    }

    // MARK: Render block

    override var internalRenderBlock: AUInternalRenderBlock {
        let kern = kernel   // capture kernel by reference; no per-block ARC overhead
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            // Pull input audio into outputData in-place
            var flags: AudioUnitRenderActionFlags = []
            let status = pullInputBlock?(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status ?? kAudioUnitErr_NoConnection }

            let ptr = UnsafeMutableAudioBufferListPointer(outputData)
            guard ptr.count >= 2,
                  let rawL = ptr[0].mData,
                  let rawR = ptr[1].mData else { return noErr }

            let ptrL = rawL.assumingMemoryBound(to: Float.self)
            let ptrR = rawR.assumingMemoryBound(to: Float.self)

            kern.process(ptrL: ptrL, ptrR: ptrR, count: Int(frameCount))
            return noErr
        }
    }
}
