import Accelerate
import Foundation

/// High-resolution (8192-pt) analysis of the stereo signal for musical notes and vocals.
///
/// Notes: energy at each semitone C2–C7, whitened against neighboring semitones so sustained pitches
/// stand out from broadband noise, with overtones of lower notes partially suppressed.
///
/// Vocals: lead vocals are almost always mixed dead center while instruments are spread wide, so the
/// "center" spectrum max(0, |mid| - 1.4|side|) in the vocal range approximates the voice. Weighted by
/// how pitched (non-noisy) that center content is, which rejects centered drums.
final class NoteAnalyzer {
    static let lowestNote = 36            // C2
    static let noteCount = 61             // through C7
    static let size = 8192

    private let log2n = vDSP_Length(13)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: NoteAnalyzer.size)
    private var midRing = [Float](repeating: 0, count: NoteAnalyzer.size)
    private var sideRing = [Float](repeating: 0, count: NoteAnalyzer.size)
    private var writeIndex = 0
    private var sinceLast = 0
    private var binHz: Float = 48000 / Float(NoteAnalyzer.size)
    private var noteBins: [Float] = []    // exact (fractional) FFT bin of each semitone
    private var vocalBins = 34...682

    private var vocalMax: Float = 1e-3
    private var sideRatio: Float = 0.3     // long-term side/mid energy; ~0 means a mono source

    private(set) var notes = [Float](repeating: 0, count: NoteAnalyzer.noteCount)
    private(set) var vocalNotes = [Float](repeating: 0, count: NoteAnalyzer.noteCount)
    private(set) var vocal: Float = 0

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(NoteAnalyzer.size), Int32(vDSP_HANN_NORM))
        configure(sampleRate: 48000)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func configure(sampleRate sr: Float) {
        binHz = sr / Float(NoteAnalyzer.size)
        noteBins = (0..<NoteAnalyzer.noteCount).map { i in
            440 * powf(2, Float(NoteAnalyzer.lowestNote + i - 69) / 12) / binHz
        }
        vocalBins = Int(200 / binHz)...Int(4000 / binHz)
    }

    /// Feed stereo samples; re-analyzes every `hop` samples. Returns true when results updated.
    @discardableResult
    func push(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>, hop: Int, gate: Bool) -> Bool {
        let n = NoteAnalyzer.size
        for i in 0..<left.count {
            midRing[writeIndex] = (left[i] + right[i]) * 0.5
            sideRing[writeIndex] = (left[i] - right[i]) * 0.5
            writeIndex = (writeIndex + 1) % n
        }
        sinceLast += left.count
        guard sinceLast >= hop else { return false }
        sinceLast = 0
        analyze(gate: gate)
        return true
    }

    private func spectrum(_ ring: [Float]) -> [Float] {
        let n = NoteAnalyzer.size
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = ring[(writeIndex + i) % n] * window[i] }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        var amps = [Float](repeating: 0, count: n / 2)
        var count = Int32(n / 2)
        vvsqrtf(&amps, mags, &count)
        return amps
    }

    private func analyze(gate: Bool) {
        guard gate else {
            for i in notes.indices { notes[i] = 0; vocalNotes[i] = 0 }
            vocal = 0
            return
        }
        let mid = spectrum(midRing)
        let side = spectrum(sideRing)

        // Track how stereo the source is; on (near) mono material the center trick can't isolate vocals.
        var midE: Float = 0, sideE: Float = 0
        for i in vocalBins { midE += mid[i] * mid[i]; sideE += side[i] * side[i] }
        if midE > 1e-9 { sideRatio += (min(1, sideE / midE) - sideRatio) * 0.02 }
        let stereo = min(1, sideRatio / 0.05)

        var total = [Float](repeating: 0, count: mid.count)
        var center = [Float](repeating: 0, count: mid.count)
        for i in 0..<mid.count {
            total[i] = (mid[i] * mid[i] + side[i] * side[i]).squareRoot()
            center[i] = max(0, mid[i] - 1.4 * side[i]) * stereo + mid[i] * 0.25 * (1 - stereo)
        }

        notes = noteStrengths(total)

        // Pitchedness of the center channel: 1 - spectral flatness over the vocal range.
        var logSum: Float = 0, linSum: Float = 0, energy: Float = 0
        for i in vocalBins {
            let p = center[i] * center[i] + 1e-12
            logSum += logf(p); linSum += p; energy += p
        }
        let count = Float(vocalBins.count)
        let flatness = expf(logSum / count) / (linSum / count)
        let pitched = min(1, max(0, (0.35 - flatness) / 0.3))
        let raw = energy.squareRoot() * pitched * (0.4 + 0.6 * stereo)
        vocalMax = max(raw, vocalMax * 0.9985, 1e-4)
        vocal = min(1, raw / vocalMax)

        let centerNotes = noteStrengths(center)
        for i in 0..<NoteAnalyzer.noteCount {
            let midi = NoteAnalyzer.lowestNote + i
            let inRange: Float = (midi >= 45 && midi <= 84) ? 1 : 0      // A2–C6, singing range
            vocalNotes[i] = centerNotes[i] * inRange * pitched * min(1, vocal * 1.5)
        }
    }

    private func noteStrengths(_ amps: [Float]) -> [Float] {
        var db = [Float](repeating: -120, count: NoteAnalyzer.noteCount)
        // Sample each semitone at its exact frequency: low semitones are only ~1 bin apart, so taking
        // the max over a window would make neighbors read the same bin.
        for (i, bin) in noteBins.enumerated() {
            let b = min(Int(bin), amps.count - 2)
            let f = bin - Float(b)
            db[i] = 20 * log10f(amps[b] * (1 - f) + amps[b + 1] * f + 1e-9)
        }
        // Contrast against neighboring semitones, but never against a floor more than 50 dB under the
        // loudest note (otherwise leakage into near-silent regions looks like a huge peak).
        let peak = db.max() ?? -120
        var out = [Float](repeating: 0, count: NoteAnalyzer.noteCount)
        for i in 0..<db.count {
            var sum: Float = 0, c: Float = 0
            for j in max(0, i - 6)...min(db.count - 1, i + 6) where j != i { sum += db[j]; c += 1 }
            let local = max(sum / c, peak - 50)
            let contrast = min(1, max(0, (db[i] - local - 6) / 18))
            let loud = min(1, max(0, (db[i] - (peak - 30)) / 12))
            // Only local maxima are notes; their neighbors are just the same peak's skirt.
            let isPeak = (i == 0 || db[i] >= db[i - 1]) && (i == db.count - 1 || db[i] >= db[i + 1])
            out[i] = contrast * loud * (isPeak ? 1 : 0.15)
        }
        // Overtone suppression: octave, twelfth and double octave above a strong note are mostly its harmonics.
        let raw = out
        for i in 0..<out.count {
            var h: Float = 0
            if i >= 12 { h += 0.8 * raw[i - 12] }
            if i >= 19 { h += 0.6 * raw[i - 19] }
            if i >= 24 { h += 0.5 * raw[i - 24] }
            out[i] = max(0, raw[i] - h)
        }
        // Keep only the strongest few notes (real piano smears energy everywhere: pedal, resonance).
        let strongest = out.max() ?? 0
        let ranked = out.indices.sorted { out[$0] > out[$1] }
        for (rank, i) in ranked.enumerated() where rank >= 6 || out[i] < max(0.15, strongest * 0.45) {
            out[i] *= 0.15
        }
        return out
    }
}
