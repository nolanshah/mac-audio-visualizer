import Accelerate
import Foundation

/// Snapshot of everything the renderer needs from the audio, published ~94x/sec.
struct AudioFeatures {
    var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var beatCount = 0
    var beatStrength: Float = 0
    var beatPeriod: Float = 0.5
    var locked = false
    var lastBeatTime: Double = 0
    var hitCount = 0
    var bpm: Float = 0
    var notes = [Float](repeating: 0, count: NoteAnalyzer.noteCount)
    var vocalNotes = [Float](repeating: 0, count: NoteAnalyzer.noteCount)
    var vocal: Float = 0
    var waveLeft = [Float](repeating: 0, count: AudioAnalyzer.waveLength)
    var waveRight = [Float](repeating: 0, count: AudioAnalyzer.waveLength)
}

/// Stereo PCM in -> log-spaced spectrum, energy envelopes, beats, notes, vocals and the raw waveform out.
final class AudioAnalyzer {
    static let bandCount = 64
    static let waveLength = 1024
    static let fftSize = 2048
    static let hop = 512

    private let log2n = vDSP_Length(11)
    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var frame = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var incoming: [Float] = []
    private var real = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var imag = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var mags = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)

    private var sampleRate: Float = 0
    private var bandCenters = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var bandBins: [(lo: Int, hi: Int, center: Float)] = []
    private var lowBins = 1...6
    private var highBins = 150...400

    // Automatic gain: references decay slowly so quiet tracks still fill the range.
    private var dbRef: Float = -30
    private var featureMax: [Float] = [0.3, 0.3, 0.3]

    // Spectral flux onset detection.
    private var prevLow: [Float] = []
    private var prevHigh: [Float] = []
    private var prevBroad: [Float] = []
    private var broadBins = 13...341
    private var highHist = [Float](repeating: 0, count: 70)
    private var histIndex = 0
    private var clock: Double = 0
    private var lastHit: Double = -10
    private var tracker: BeatTracker?
    private var pendingLead: Double?

    private let noteAnalyzer = NoteAnalyzer()
    private var waveL = [Float](repeating: 0, count: AudioAnalyzer.waveLength)
    private var waveR = [Float](repeating: 0, count: AudioAnalyzer.waveLength)
    private var mono: [Float] = []
    private var lastLevel: Float = 0

    private var current = AudioFeatures()
    private let lock = NSLock()

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(AudioAnalyzer.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Fire beats this many seconds early to line up with what you hear (adjustable live).
    var beatLead: Double {
        get { lock.lock(); defer { lock.unlock() }; return pendingLead ?? tracker?.lead ?? 0.03 }
        set { lock.lock(); pendingLead = newValue; lock.unlock() }
    }

    var trackerDebug: String {
        lock.lock(); defer { lock.unlock() }
        return tracker?.debugDescription ?? "-"
    }

    var features: AudioFeatures {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    private func configure(sampleRate sr: Float) {
        sampleRate = sr
        let binHz = sr / Float(AudioAnalyzer.fftSize)
        let maxBin = AudioAnalyzer.fftSize / 2 - 1
        let fMin: Float = 32, fMax: Float = 16000
        bandBins = (0..<AudioAnalyzer.bandCount).map { b in
            let f0 = fMin * powf(fMax / fMin, Float(b) / Float(AudioAnalyzer.bandCount))
            let f1 = fMin * powf(fMax / fMin, Float(b + 1) / Float(AudioAnalyzer.bandCount))
            let c = sqrtf(f0 * f1)
            bandCenters[b] = c
            return (min(Int(f0 / binHz), maxBin), min(Int(f1 / binHz), maxBin), c / binHz)
        }
        lowBins = 1...max(2, Int(150 / binHz))
        highBins = Int(3500 / binHz)...min(maxBin, Int(9000 / binHz))
        prevLow = [Float](repeating: 0, count: lowBins.count)
        prevHigh = [Float](repeating: 0, count: highBins.count)
        broadBins = Int(300 / binHz)...min(maxBin, Int(8000 / binHz))
        prevBroad = [Float](repeating: 0, count: broadBins.count)
        noteAnalyzer.configure(sampleRate: sr)
        let lead = tracker?.lead ?? 0.03
        tracker = BeatTracker(framesPerSecond: Double(sr) / Double(AudioAnalyzer.hop))
        tracker?.lead = lead
    }

    /// Called on the capture queue with stereo samples (pass the same buffer twice for mono).
    func process(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>, sampleRate sr: Float) {
        if sr != sampleRate { configure(sampleRate: sr) }
        let count = min(left.count, right.count)
        if mono.count != count { mono = [Float](repeating: 0, count: count) }
        for i in 0..<count { mono[i] = (left[i] + right[i]) * 0.5 }

        // Latest raw waveform for the oscilloscope.
        let w = AudioAnalyzer.waveLength
        if count >= w {
            for i in 0..<w { waveL[i] = left[count - w + i]; waveR[i] = right[count - w + i] }
        } else {
            waveL.removeFirst(count); waveL.append(contentsOf: left[0..<count])
            waveR.removeFirst(count); waveR.append(contentsOf: right[0..<count])
        }
        let notesUpdated = noteAnalyzer.push(left: left, right: right, hop: 1024, gate: lastLevel > 0.05)
        lock.lock()
        current.waveLeft = waveL
        current.waveRight = waveR
        if notesUpdated {
            current.notes = noteAnalyzer.notes
            current.vocalNotes = noteAnalyzer.vocalNotes
            current.vocal = noteAnalyzer.vocal
        }
        lock.unlock()

        incoming.append(contentsOf: mono)
        let hop = AudioAnalyzer.hop
        while incoming.count >= hop {
            frame.removeFirst(hop)
            frame.append(contentsOf: incoming[0..<hop])
            incoming.removeFirst(hop)
            analyze()
        }
    }

    private func analyze() {
        let n = AudioAnalyzer.fftSize
        let dt = Double(AudioAnalyzer.hop) / Double(sampleRate)
        clock += dt

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))
        let silent = rms < 1e-5

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        mags[0] = 0
        var amps = [Float](repeating: 0, count: n / 2)
        var count = Int32(n / 2)
        vvsqrtf(&amps, mags, &count)

        // Log-spaced bands with a +3dB/octave tilt so treble isn't buried under bass.
        var bandDb = [Float](repeating: -120, count: AudioAnalyzer.bandCount)
        var frameMax: Float = -120
        for (b, r) in bandBins.enumerated() {
            var a: Float
            if r.hi <= r.lo {
                let i = min(Int(r.center), n / 2 - 2)
                let f = r.center - Float(i)
                a = amps[i] * (1 - f) + amps[i + 1] * f
            } else {
                a = 0
                for i in r.lo...r.hi { a = max(a, amps[i]) }
            }
            let db = 20 * log10f(a + 1e-9) + 3 * log2f(bandCenters[b] / 500)
            bandDb[b] = db
            frameMax = max(frameMax, db)
        }
        if frameMax > dbRef { dbRef = frameMax } else { dbRef = max(-60, dbRef - Float(dt) * 2.5) }

        var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
        if !silent {
            let range: Float = 42
            for b in 0..<bands.count {
                let v = min(1, max(0, (bandDb[b] - (dbRef - range)) / range))
                bands[b] = v * v
            }
        }

        // Bass / mid / treble envelopes, each with its own slow AGC.
        var sums: [Float] = [0, 0, 0], counts: [Float] = [0, 0, 0]
        for b in 0..<bands.count {
            let c = bandCenters[b]
            let k = c < 160 ? 0 : (c < 2200 ? 1 : 2)
            sums[k] += bands[b]; counts[k] += 1
        }
        var env = [Float](repeating: 0, count: 3)
        let decay = powf(0.5, Float(dt) / 4)
        for k in 0..<3 {
            let x = sums[k] / max(counts[k], 1)
            featureMax[k] = max(0.12, max(featureMax[k] * decay, x))
            env[k] = silent ? 0 : min(1, x / featureMax[k])
        }
        let level: Float = silent ? 0 : min(1, max(0, (20 * log10f(rms) + 48) / 42))

        // Onsets: spectral flux against an adaptive mean + k*std threshold.
        var lowFlux: Float = 0
        for (j, i) in lowBins.enumerated() {
            let v = logf(1 + amps[i])
            lowFlux += max(0, v - prevLow[j]); prevLow[j] = v
        }
        var highFlux: Float = 0
        for (j, i) in highBins.enumerated() {
            let v = logf(1 + amps[i] * 4)
            highFlux += max(0, v - prevHigh[j]); prevHigh[j] = v
        }
        var broadFlux: Float = 0
        for (j, i) in broadBins.enumerated() {
            let v = logf(1 + amps[i] * 4)
            broadFlux += max(0, v - prevBroad[j]); prevBroad[j] = v
        }
        broadFlux /= Float(broadBins.count)
        let isHit = onset(highFlux, history: highHist, k: 2.0)
        highHist[histIndex % highHist.count] = highFlux
        histIndex += 1

        lock.lock()
        if let lead = pendingLead { tracker?.lead = lead; pendingLead = nil }
        lock.unlock()
        let beat = tracker?.process(low: lowFlux, broad: broadFlux, time: clock, active: !silent && level > 0.05)

        lastLevel = level
        lock.lock()
        current.bands = bands
        current.bass = env[0]
        current.mid = env[1]
        current.treble = env[2]
        current.level = level
        if let tracker {
            current.bpm = tracker.bpm
            current.locked = tracker.isLocked
            current.beatPeriod = Float(tracker.period)
        }
        if let beat {
            current.beatCount += 1
            current.beatStrength = beat.strength
            current.lastBeatTime = beat.time
        }
        if !silent && isHit && clock - lastHit > 0.09 {
            lastHit = clock
            current.hitCount += 1
        }
        lock.unlock()
    }

    private func onset(_ x: Float, history: [Float], k: Float) -> Bool {
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(history, 1, nil, 1, &mean, &sd, vDSP_Length(history.count))
        return x > mean + k * sd && x > mean * 1.3 && x > 0.05
    }
}
