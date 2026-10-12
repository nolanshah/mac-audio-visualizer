import AppKit
import Metal

/// Headless render with a synthetic beat, used to check the look without live audio.
enum Snapshot {
    static func run(outputDirectory: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? Renderer(device: device, outputFormat: .bgra8Unorm) else {
            print("Metal setup failed"); return
        }
        precondition(MemoryLayout<Uniforms>.stride == 160, "Uniforms layout mismatch")

        func features(_ frame: Int) -> AudioFeatures {
            var f = AudioFeatures()
            let t = Float(frame) / 60
            let beatPhase = fmodf(t, 0.5) / 0.5             // 120 BPM
            let kick = expf(-beatPhase * 6)
            f.bands = (0..<AudioAnalyzer.bandCount).map { b in
                let x = Float(b) / Float(AudioAnalyzer.bandCount)
                let shape = 0.85 - 0.5 * x + 0.15 * sinf(x * 23 + t * 3)
                return max(0, min(1, shape * (x < 0.2 ? 0.5 + 0.5 * kick : 0.8)))
            }
            f.bass = 0.4 + 0.6 * kick
            f.mid = 0.6
            f.treble = 0.5
            f.level = 0.75
            f.beatCount = Int(t / 0.5)
            f.beatStrength = 0.8
            f.beatPeriod = 0.5
            f.hitCount = Int(t / 0.25)
            // A chord progression in the keys, a sung melody on top, and a stereo waveform.
            let chords = [[12, 16, 19, 24], [9, 12, 16, 21], [5, 9, 12, 17], [7, 11, 14, 19]]
            let chord = chords[Int(t / 0.7) % chords.count]
            for n in chord { f.notes[n] = 0.8 }
            f.notes[chord[0] - 12 >= 0 ? chord[0] - 12 : 0] = 0.9
            let melody = [33, 36, 38, 36, 35, 31, 33, 28]
            let m = melody[Int(t / 0.35) % melody.count]
            f.notes[m] = 0.9
            f.vocalNotes[m] = 0.9
            f.vocal = 0.7
            for i in 0..<AudioAnalyzer.waveLength {
                let x = t + Float(i) / 48000
                let base = 0.5 * sinf(2 * .pi * 110 * x) + 0.25 * sinf(2 * .pi * 330 * x + 1) + 0.15 * sinf(2 * .pi * 880 * x)
                f.waveLeft[i] = base + 0.12 * sinf(2 * .pi * 523 * x)
                f.waveRight[i] = base - 0.12 * sinf(2 * .pi * 659 * x)
            }
            return f
        }

        for (m, name) in Renderer.modeNames.enumerated() {
            for (pi, palette) in [Palette.presets[0], Palette.presets[1]].enumerated() {
                renderer.setMode(m)
                renderer.targetPalette = palette.colors
                guard let image = renderer.snapshot(width: 1280, height: 800, frames: 170, features: features) else { continue }
                let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("mode\(m)-\(pi)-\(name.replacingOccurrences(of: " ", with: "")).png")
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }
}

/// Feeds synthetic tracks through the analyzer and scores beat timing against the true kick times.
enum SelfTest {
    struct Track {
        var name: String
        var seconds: Int
        var kickPeriod: Float?          // nil = no kicks
        var offbeatBass: Bool
        var hats: Bool
    }

    static func run() {
        let tracks = [
            Track(name: "120bpm four-on-floor", seconds: 12, kickPeriod: 0.5, offbeatBass: false, hats: true),
            Track(name: "90bpm kick + offbeat bassline", seconds: 14, kickPeriod: 60.0 / 90, offbeatBass: true, hats: true),
            Track(name: "ambient pad, no kicks", seconds: 12, kickPeriod: nil, offbeatBass: false, hats: false),
        ]
        for t in tracks { runTrack(t) }
        if CommandLine.arguments.contains("--pure") {
            let sr: Float = 48000
            let a = AudioAnalyzer()
            var buf = [Float](repeating: 0, count: 1024)
            for c in 0..<100 {
                for i in 0..<1024 { buf[i] = 0.3 * sinf(2 * .pi * 440 * Float(c * 1024 + i) / sr) }
                buf.withUnsafeBufferPointer { a.process(left: $0, right: $0, sampleRate: sr) }
            }
            let f = a.features
            print("pure 440:", f.notes.enumerated().filter { $0.element > 0.01 }.map { "\($0.offset + NoteAnalyzer.lowestNote):\(String(format: "%.2f", $0.element))" })
            return
        }
        notesTest(withVoice: true)
        notesTest(withVoice: false)
    }

    /// Wide C-major chord (C3 left, E3 right, G3 both sides out of phase) plus an optional centered "voice" on A4.
    private static func notesTest(withVoice: Bool) {
        let sr: Float = 48000
        let analyzer = AudioAnalyzer()
        let total = Int(sr) * 3
        var l = [Float](repeating: 0, count: total), r = [Float](repeating: 0, count: total)
        func tone(_ f: Float, _ t: Float) -> Float { sinf(2 * .pi * f * t) + 0.5 * sinf(4 * .pi * f * t) + 0.25 * sinf(6 * .pi * f * t) }
        for i in 0..<total {
            let t = Float(i) / sr
            let c3 = tone(130.81, t) * 0.12, e3 = tone(164.81, t) * 0.12, g3 = tone(196.0, t) * 0.12
            l[i] = c3 + g3 * 0.7
            r[i] = e3 - g3 * 0.7
            if withVoice {
                // Proper vibrato: +/-0.6% frequency deviation at 5.5 Hz applied to the phase.
                let ph = 2 * Float.pi * 440 * t + (440 * 0.006 / 5.5) * sinf(2 * .pi * 5.5 * t)
                let v = (sinf(ph) + 0.5 * sinf(2 * ph) + 0.25 * sinf(3 * ph)) * 0.15
                l[i] += v; r[i] += v
            }
        }
        for start in stride(from: 0, to: total, by: 1024) {
            let end = min(start + 1024, total)
            l[start..<end].withUnsafeBufferPointer { lp in
                r[start..<end].withUnsafeBufferPointer { rp in analyzer.process(left: lp, right: rp, sampleRate: sr) }
            }
        }
        let f = analyzer.features
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        func name(_ i: Int) -> String { let m = NoteAnalyzer.lowestNote + i; return "\(names[m % 12])\(m / 12 - 1)" }
        let top = f.notes.indices.sorted { f.notes[$0] > f.notes[$1] }.prefix(5).filter { f.notes[$0] > 0.05 }
        let topVocal = f.vocalNotes.indices.sorted { f.vocalNotes[$0] > f.vocalNotes[$1] }.prefix(2).filter { f.vocalNotes[$0] > 0.05 }
        print(String(format: "notes test (voice=%@): vocal=%.2f notes=%@ vocalNotes=%@", withVoice ? "yes" : "no", f.vocal,
                     top.map { "\(name($0)):\(String(format: "%.2f", f.notes[$0]))" }.joined(separator: " "),
                     topVocal.map { "\(name($0)):\(String(format: "%.2f", f.vocalNotes[$0]))" }.joined(separator: " ")))
    }

    private static func runTrack(_ track: Track) {
        let sr: Float = 48000
        let analyzer = AudioAnalyzer()
        analyzer.beatLead = 0
        var seed: UInt32 = 1
        func noise() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(seed >> 8) / Float(1 << 24) * 2 - 1
        }
        let total = Int(sr) * track.seconds
        var samples = [Float](repeating: 0, count: total)
        var lp: Float = 0
        for i in 0..<total {
            let t = Float(i) / sr
            var s: Float = 0
            if let kp = track.kickPeriod {
                let kt = fmodf(t, kp)
                s += sinf(2 * .pi * (50 + 60 * expf(-kt * 40)) * kt) * expf(-kt * 9) * 0.8
                if kt < 0.006 { s += noise() * 0.12 * (1 - kt / 0.006) }   // beater click
                if track.offbeatBass {
                    let bt = fmodf(t + kp / 2, kp)      // bass note starts on each offbeat
                    s += (sinf(2 * .pi * 73 * bt) + 0.35 * sinf(2 * .pi * 146 * bt) + 0.15 * sinf(2 * .pi * 219 * bt))
                        * expf(-bt * 4) * 0.55
                }
                if track.hats {
                    let ht = fmodf(t, kp / 2)
                    if ht < 0.02 { s += noise() * 0.2 * (1 - ht / 0.02) }
                }
            } else {
                lp += (noise() - lp) * 0.02          // soft brown-ish noise bed
                s += lp * 0.6 + 0.08 * sinf(2 * .pi * 110 * t) * (0.6 + 0.4 * sinf(t * 0.7))
            }
            s += 0.04 * (sinf(2 * .pi * 440 * t) + sinf(2 * .pi * 554 * t))
            samples[i] = s
        }

        var beatTimes: [Double] = []
        var lastCount = 0
        for start in stride(from: 0, to: total, by: 1024) {
            samples[start..<min(start + 1024, total)].withUnsafeBufferPointer { analyzer.process(left: $0, right: $0, sampleRate: sr) }
            let f = analyzer.features
            if f.beatCount != lastCount { lastCount = f.beatCount; beatTimes.append(f.lastBeatTime) }
        }
        let f = analyzer.features
        var line = String(format: "%-32@ beats=%3d bpm=%5.1f locked=%@ [%@]", track.name as NSString, beatTimes.count, f.bpm,
                          f.locked ? "yes" : "no", analyzer.trackerDebug as NSString)
        if let kp = track.kickPeriod.map(Double.init) {
            // Score beats after a 4 s warm-up.
            let scored = beatTimes.filter { $0 > 4 }
            var errs: [Double] = []
            var offbeat = 0
            for b in scored {
                let e = b - (b / kp).rounded() * kp
                if abs(e) > kp / 4 { offbeat += 1 } else { errs.append(e) }
            }
            let expected = Int(Double(track.seconds - 4) / kp)
            let meanAbs = errs.isEmpty ? 0 : errs.map(abs).reduce(0, +) / Double(errs.count) * 1000
            let bias = errs.isEmpty ? 0 : errs.reduce(0, +) / Double(errs.count) * 1000
            line += String(format: "  after warmup: %d/%d on kicks, %d off-beat, |err| %.1f ms, bias %+.1f ms",
                           errs.count, expected, offbeat, meanAbs, bias)
        }
        print(line)
    }
}

/// GPU cost per frame for each mode at a given size: Visualizer --bench 3024 1964
enum Bench {
    static func run(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? Renderer(device: device, outputFormat: .bgra8Unorm) else { return }
        for (m, name) in Renderer.modeNames.enumerated() {
            renderer.setMode(m)
            _ = renderer.snapshot(width: width, height: height, frames: 5) { _ in AudioFeatures() }
            renderer.gpuSeconds = 0
            _ = renderer.snapshot(width: width, height: height, frames: 30) { _ in AudioFeatures() }
            print(String(format: "%-14@ %6.2f ms GPU/frame", name as NSString, renderer.gpuSeconds / 30 * 1000))
        }
    }
}
