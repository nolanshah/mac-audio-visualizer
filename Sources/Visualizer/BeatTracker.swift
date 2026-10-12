import Foundation

/// Tempo-locked beat tracker.
///
/// Raw onset detection fires on bass notes, syncopation and noise. Instead this estimates the tempo by
/// autocorrelating the low-band onset envelope (~5.5 s), then runs a beat grid whose phase is nudged by
/// onsets that land near it. Beats are emitted on the grid (slightly early, to cancel display latency),
/// so they stay on time even when a kick is soft or missing. When there's no clear pulse it goes quiet
/// and only very strong onsets get through.
final class BeatTracker {
    struct Beat {
        var time: Double
        var strength: Float
    }

    private let fps: Double
    private var env = [Float](repeating: 0, count: 512)
    private var count = 0

    // Running means used to put the low and broadband flux on the same scale.
    private var lowMean: Float = 1e-3
    private var broadMean: Float = 1e-3

    // Where in the beat cycle strong onsets land (grid-relative), to pick kicks over offbeat bass.
    private var phaseHist = [Float](repeating: 0, count: 20)

    // Onset peak picking with running z-score.
    private var mean: Float = 0
    private var variance: Float = 1e-4
    private var prev2: Float = 0
    private var prev1: Float = 0
    private var prev1Z: Float = 0

    // Tempo.
    private(set) var period: Double = 0.5
    private var hasTempo = false
    private var candidate: Double = 0
    private var candidateHits = 0
    private var confidence: Float = 0
    private var acfSmooth: [Float] = []

    // Phase.
    private var nextBeat = Double.infinity
    private var lastMatched: Double = -100
    private var lastEmit: Double = -100
    private var accent: Float = 0.5

    /// Seconds to fire before the predicted beat (display + capture latency compensation).
    var lead: Double = 0.03
    /// Hann-windowed flux peaks this long after the audible attack.
    private let detectionDelay: Double = 0.018

    init(framesPerSecond: Double) {
        fps = framesPerSecond
    }

    // Lock on evidence that the grid works: the share of recent grid beats that landed on a real onset.
    // Hysteresis keeps it from flickering on songs with a few soft bars.
    private var matchScore: Float = 0
    private var confident = false
    var isLocked: Bool { hasTempo && confident && lastEmitClock - lastMatched < 4 * period }
    var bpm: Float { isLocked ? Float(60 / period) : 0 }
    var debugDescription: String {
        String(format: "tempo=%@ period=%.3f conf=%.2f match=%.2f sinceMatch=%.1fs",
               hasTempo ? "yes" : "no", period, confidence, matchScore, lastEmitClock - lastMatched)
    }
    private var lastEmitClock: Double = 0

    /// Feed one analysis frame. `low` is kick-band flux, `broad` is 300 Hz–8 kHz flux (clicks, snares, claps).
    /// Returns a beat if one should be shown now.
    func process(low: Float, broad: Float, time: Double, active: Bool) -> Beat? {
        lastEmitClock = time
        let k = Float(1 / (fps * 4))
        lowMean += k * (low - lowMean)
        broadMean += k * (broad - broadMean)
        // Kicks carry a broadband click; bass notes don't. Weighting broadband flux in favors the beat.
        let flux = low / max(lowMean, 1e-4) + 0.8 * broad / max(broadMean, 1e-4)
        env[count % env.count] = flux
        count += 1

        // Peak pick on the previous frame so we know it's a local maximum.
        var onset: (time: Double, z: Float)?
        if prev1 > prev2 && prev1 >= flux && prev1Z > 1.6 && active {
            onset = (time - 1 / fps - detectionDelay, prev1Z)
        }
        let z = (flux - mean) / max(sqrtf(variance), 1e-4)
        let a = Float(1 / (fps * 2))
        let d = flux - mean
        mean += a * d
        variance += a * (d * d - variance)
        prev2 = prev1; prev1 = flux; prev1Z = z

        if count % Int(fps / 2) == 0 && count >= env.count / 2 {
            estimateTempo()
            realignPhase()
        }

        if let onset { handleOnset(at: onset.time, z: onset.z) }

        // Emit on the grid while locked.
        var beat: Beat?
        if nextBeat.isFinite {
            var guardCount = 0
            while time + lead >= nextBeat && guardCount < 8 {
                // Judge the previous grid slot, whose matching window has closed by now.
                let judged = nextBeat - period
                let hit: Float = abs(lastMatched - judged) < 0.16 * period ? 1 : 0
                matchScore += (hit - matchScore) * 0.2
                if matchScore > 0.45 { confident = true } else if matchScore < 0.25 { confident = false }
                if active && isLocked && nextBeat - lastEmit > period * 0.5 {
                    beat = Beat(time: nextBeat, strength: accent)
                    lastEmit = nextBeat
                }
                nextBeat += period
                guardCount += 1
            }
        }

        // Unlocked fallback: only unmistakable hits get through.
        if beat == nil, !isLocked, let onset, onset.z > 3.5, time - lastEmit > 0.35 {
            beat = Beat(time: onset.time, strength: min(1, (onset.z - 3) / 4))
            lastEmit = time
        }
        return beat
    }

    private func handleOnset(at t: Double, z: Float) {
        let strength = min(1, max(0.2, (z - 1.5) / 3.5))
        guard hasTempo else { return }
        if !nextBeat.isFinite || t - lastMatched > 4 * period {
            // (Re)anchor the grid to any clear onset; phase realignment moves it onto the
            // strongest beat position afterwards if this one was an offbeat.
            nextBeat = t + period
            lastMatched = t
            accent = strength
            return
        }
        var ph = (t - nextBeat) / period
        ph -= ph.rounded(.down)
        for i in phaseHist.indices { phaseHist[i] *= 0.98 }
        phaseHist[min(phaseHist.count - 1, Int(ph * Double(phaseHist.count)))] += z

        let prevBeat = nextBeat - period
        let err = abs(t - prevBeat) < abs(t - nextBeat) ? t - prevBeat : t - nextBeat
        if abs(err) < 0.15 * period {
            nextBeat += err * 0.35
            lastMatched = t
            accent += (strength - accent) * 0.3
        }
    }

    /// If onsets consistently cluster away from the grid (e.g. we locked onto offbeat bass), shift the grid there.
    private func realignPhase() {
        guard hasTempo, nextBeat.isFinite else { return }
        let n = phaseHist.count
        func smoothed(_ i: Int) -> Float {
            phaseHist[(i + n - 1) % n] * 0.5 + phaseHist[i] + phaseHist[(i + 1) % n] * 0.5
        }
        var best = 0
        for i in 0..<n where smoothed(i) > smoothed(best) { best = i }
        var offset = (Double(best) + 0.5) / Double(n)
        if offset > 0.5 { offset -= 1 }
        let here = max(smoothed(0), smoothed(n - 1))
        guard abs(offset) > 0.12, smoothed(best) > 1.4 * here + 1 else { return }
        nextBeat += offset * period
        let shift = best
        phaseHist = (0..<n).map { phaseHist[($0 + shift) % n] }
    }

    private func estimateTempo() {
        let n = min(count, env.count)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = env[(count - n + i) % env.count] }
        let m = x.reduce(0, +) / Float(n)
        for i in 0..<n { x[i] -= m }
        var e0: Float = 0
        for v in x { e0 += v * v }
        e0 /= Float(n)
        guard e0 > 1e-6 else { confidence *= 0.5; return }

        let minLag = Int(fps * 60 / 180)
        let maxLag = min(n / 2, Int(fps * 60 / 65))
        guard maxLag > minLag + 2 else { return }
        var acf = [Float](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var s: Float = 0
            for i in lag..<n { s += x[i] * x[i - lag] }
            acf[lag] = s / Float(n - lag) / e0
        }
        // Average the autocorrelation over successive estimates so the tempo settles instead of wandering.
        if acfSmooth.count != acf.count { acfSmooth = acf }
        for i in acf.indices { acfSmooth[i] += (acf[i] - acfSmooth[i]) * 0.25; acf[i] = acfSmooth[i] }
        // Prefer tempos near 115 BPM to resolve half/double-time ambiguity.
        var best = minLag
        var bestScore = -Float.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let w = Float(exp(-0.5 * pow(log2(bpm / 115) / 0.9, 2)))
            let score = acf[lag] * w
            if score > bestScore { bestScore = score; best = lag }
        }
        // Parabolic refinement for sub-frame precision.
        let y0 = acf[best - 1], y1 = acf[best], y2 = acf[best + 1]
        let denom = y0 - 2 * y1 + y2
        let offset = denom != 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom)) : 0
        let newPeriod = (Double(best) + Double(offset)) / fps
        let conf = max(0, acf[best])
        confidence += (conf - confidence) * 0.4

        if !hasTempo {
            if conf > 0.2 { period = newPeriod; hasTempo = true }
        } else if abs(newPeriod / period - 1) < 0.06 {
            period += (newPeriod - period) * 0.3
            candidateHits = 0
        } else {
            if abs(newPeriod / max(candidate, 1e-3) - 1) < 0.06 { candidateHits += 1 } else { candidate = newPeriod; candidateHits = 1 }
            if candidateHits >= 6 { period = newPeriod; candidateHits = 0 }
        }
    }
}
