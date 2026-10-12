import MetalKit
import QuartzCore
import simd

struct Uniforms {
    var c0 = SIMD4<Float>(repeating: 0), c1 = SIMD4<Float>(repeating: 0)
    var c2 = SIMD4<Float>(repeating: 0), c3 = SIMD4<Float>(repeating: 0)
    var resolution = SIMD2<Float>(1, 1)
    var time: Float = 0, phase: Float = 0
    var bass: Float = 0, mid: Float = 0, treble: Float = 0, level: Float = 0
    var beat: Float = 0, hit: Float = 0, mode: Float = 0, beatCount: Float = 0
    var kick: Float = 0, frameScale: Float = 1, intensity: Float = 1, beatStrength: Float = 0
    var historyHead: Float = 0, historyFrac: Float = 0, beatPhase: Float = 1, beatTravel: Float = 0
    var vocal: Float = 0, energy: Float = 0, noteHead: Float = 0, noteFrac: Float = 0
}

/// Per-draw parameters for the oscilloscope beam pass.
struct LineParams {
    var aspect: Float = 1
    var width: Float = 0.006
    var intensity: Float = 1
    var hue: Float = 0
}

final class Renderer: NSObject, MTKViewDelegate {
    static let modeNames = ["Silk", "Nebula Tunnel", "Ribbons", "Aurora", "Contours", "Halo", "Ridgeline", "Bokeh", "Chrome",
                            "Kaleidoscope", "Keys", "Bars", "Scope"]
    static let scopeMode = 12
    static let historyRows = 40
    static let historyRate: Float = 10      // Ridgeline rows per second; each row averages its interval
    static let noteRows = 128
    static let noteRate: Float = 40         // Keys piano-roll rows per second

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let feedbackPipeline: MTLRenderPipelineState
    private let postPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var feedback: [MTLTexture] = []
    private var feedbackIndex = 0

    var featuresProvider: () -> AudioFeatures = { AudioFeatures() }
    var mode = 0
    var targetPalette = Palette.presets[0].colors

    private var u = Uniforms()
    private var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var palette = Palette.presets[0].colors
    private var lastBeatCount = 0
    private var lastHitCount = 0
    private var beatsSeen: Float = 0
    private var lastBeatAt: Float = -10
    private var beatPeriod: Float = 0.5
    private var lastTime = CACurrentMediaTime()

    // Rolling spectrum history (newest row at historyHead) for the Ridgeline mode.
    private let history: MTLBuffer
    private var historyHead = 0
    private var historyClock: Float = 0
    private var historySum = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var historySamples: Float = 0

    // Each band normalized by its own slow peak, so every range uses its full brightness (Bokeh, Bars).
    private var flatBands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var flatMax = [Float](repeating: 0.1, count: AudioAnalyzer.bandCount)
    // Falling peak caps for Bars.
    private var peaks = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var peakVelocity = [Float](repeating: 0, count: AudioAnalyzer.bandCount)

    // Piano roll: rows of (note energy, vocal energy) pairs, newest at noteHead.
    private let noteHistory: MTLBuffer
    private var noteHead = 0
    private var noteClock: Float = 0
    private var notes = [Float](repeating: 0, count: NoteAnalyzer.noteCount)
    private var vocalNotes = [Float](repeating: 0, count: NoteAnalyzer.noteCount)

    // Oscilloscope.
    private var wave = AudioFeatures().waveLeft
    private var waveRight = AudioFeatures().waveRight
    private var wavePeak: Float = 0.05
    private var scopeRing = [Float](repeating: 0, count: 480)

    init(device: MTLDevice, outputFormat: MTLPixelFormat) throws {
        self.device = device
        queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(source: Shaders.source, options: nil)

        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vmain")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        feedbackPipeline = try pipeline("feedbackFrag", .rgba16Float)
        postPipeline = try pipeline("postFrag", outputFormat)

        let ld = MTLRenderPipelineDescriptor()
        ld.vertexFunction = library.makeFunction(name: "lineVert")
        ld.fragmentFunction = library.makeFunction(name: "lineFrag")
        ld.colorAttachments[0].pixelFormat = .rgba16Float
        ld.colorAttachments[0].isBlendingEnabled = true
        ld.colorAttachments[0].rgbBlendOperation = .add
        ld.colorAttachments[0].alphaBlendOperation = .add
        ld.colorAttachments[0].sourceRGBBlendFactor = .one
        ld.colorAttachments[0].destinationRGBBlendFactor = .one
        ld.colorAttachments[0].sourceAlphaBlendFactor = .zero
        ld.colorAttachments[0].destinationAlphaBlendFactor = .one
        linePipeline = try device.makeRenderPipelineState(descriptor: ld)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!
        history = device.makeBuffer(length: Renderer.historyRows * AudioAnalyzer.bandCount * MemoryLayout<Float>.stride,
                                    options: .storageModeShared)!
        noteHistory = device.makeBuffer(length: Renderer.noteRows * 64 * 2 * MemoryLayout<Float>.stride,
                                        options: .storageModeShared)!
        super.init()
    }

    // MARK: - Per-frame state

    /// Turns raw analyzer output into smooth, punchy animation parameters.
    func update(dt: Float, time: Float) {
        let f = featuresProvider()
        func follow(_ cur: Float, _ target: Float, up: Float, down: Float) -> Float {
            let k = target > cur ? up : down
            return cur + (target - cur) * (1 - expf(-k * dt))
        }
        u.bass = follow(u.bass, f.bass * f.bass, up: 30, down: 5)
        u.mid = follow(u.mid, f.mid, up: 20, down: 4)
        u.treble = follow(u.treble, f.treble, up: 25, down: 5)
        u.level = follow(u.level, f.level, up: 10, down: 1.5)
        u.vocal = follow(u.vocal, f.vocal, up: 12, down: 3)
        u.energy = follow(u.energy, 0.6 * f.level + 0.4 * f.bass, up: 1.5, down: 0.6)
        let flatDecay = powf(0.5, dt / 5)
        for i in 0..<bands.count {
            bands[i] = follow(bands[i], f.bands[i], up: 40, down: 7)
            flatMax[i] = max(0.08, flatMax[i] * flatDecay, bands[i])
            flatBands[i] = bands[i] / flatMax[i]
            if flatBands[i] >= peaks[i] {
                peaks[i] = flatBands[i]
                peakVelocity[i] = 0
            } else {
                peakVelocity[i] += 2.2 * dt
                peaks[i] = max(0, peaks[i] - peakVelocity[i] * dt)
            }
        }
        for i in 0..<notes.count {
            notes[i] = follow(notes[i], f.notes[i], up: 14, down: 6)
            vocalNotes[i] = follow(vocalNotes[i], f.vocalNotes[i], up: 14, down: 6)
        }
        wave = f.waveLeft
        waveRight = f.waveRight

        // Beats come from the tempo-locked tracker, already aligned to the music's grid.
        if f.beatCount != lastBeatCount {
            lastBeatCount = f.beatCount
            let strength = 0.35 + 0.65 * f.beatStrength
            u.beat = strength
            u.kick = strength
            u.beatStrength = strength
            u.beatCount += 1
            beatsSeen += 1
            lastBeatAt = time
            beatPeriod = max(0.3, min(1.2, f.beatPeriod))
        }
        u.beatPhase = min(1, (time - lastBeatAt) / beatPeriod)
        let ease = 1 - powf(1 - u.beatPhase, 3)
        u.beatTravel = beatsSeen + ease
        if f.hitCount != lastHitCount {
            lastHitCount = f.hitCount
            u.hit = 1
        }
        u.beat *= expf(-dt * 3.5)
        u.kick *= expf(-dt * 9)
        u.hit *= expf(-dt * 10)

        // Flow speed follows overall energy; rhythm comes from the beat grid, not per-hit surges.
        u.phase += dt * (0.3 + 0.9 * u.level + 0.6 * u.energy)
        u.time = time
        u.frameScale = dt * 60

        // Mode switches fade up from dark so the cut feels intentional.
        u.mode = Float(mode)
        u.intensity = follow(u.intensity, 1, up: 2.5, down: 2.5)

        // Ridgeline rows are averages over their interval: calmer and easier to read than snapshots.
        for i in 0..<bands.count { historySum[i] += bands[i] }
        historySamples += 1
        historyClock += dt * Renderer.historyRate
        while historyClock >= 1 {
            historyClock -= 1
            historyHead = (historyHead + Renderer.historyRows - 1) % Renderer.historyRows
            let row = history.contents().assumingMemoryBound(to: Float.self) + historyHead * AudioAnalyzer.bandCount
            for i in 0..<bands.count { row[i] = historySum[i] / max(1, historySamples); historySum[i] = 0 }
            historySamples = 0
        }
        u.historyHead = Float(historyHead)
        u.historyFrac = historyClock

        noteClock += dt * Renderer.noteRate
        while noteClock >= 1 {
            noteClock -= 1
            noteHead = (noteHead + Renderer.noteRows - 1) % Renderer.noteRows
            let row = noteHistory.contents().assumingMemoryBound(to: Float.self) + noteHead * 128
            for i in 0..<notes.count { row[i * 2] = notes[i]; row[i * 2 + 1] = vocalNotes[i] }
        }
        u.noteHead = Float(noteHead)
        u.noteFrac = noteClock

        let k = 1 - expf(-dt * 1.2)
        for i in 0..<4 { palette[i] += (targetPalette[i] - palette[i]) * k }
        u.c0 = palette[0]; u.c1 = palette[1]; u.c2 = palette[2]; u.c3 = palette[3]
    }

    func setMode(_ m: Int) {
        mode = (m + Renderer.modeNames.count) % Renderer.modeNames.count
        u.intensity = 0.15
    }

    // MARK: - Encoding

    private func ensureTextures(width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        if let t = feedback.first, t.width == width, t.height == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        feedback = (0..<2).map { _ in device.makeTexture(descriptor: d)! }
        for t in feedback {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = t
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }

    /// Scene + feedback render at a capped pixel count (it's all soft glow) and get upscaled by the post pass,
    /// so fullscreen on a Retina display costs about the same as a window.
    static let maxScenePixels: Double = 1_100_000

    func encode(into commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        let scale = min(1, (Renderer.maxScenePixels / Double(target.width * target.height)).squareRoot())
        let sw = max(1, Int(Double(target.width) * scale)), sh = max(1, Int(Double(target.height) * scale))
        ensureTextures(width: sw, height: sh, commandBuffer: commandBuffer)
        u.resolution = SIMD2(Float(sw), Float(sh))
        let prev = feedback[feedbackIndex]
        let next = feedback[1 - feedbackIndex]
        feedbackIndex = 1 - feedbackIndex

        let fbPass = MTLRenderPassDescriptor()
        fbPass.colorAttachments[0].texture = next
        fbPass.colorAttachments[0].loadAction = .dontCare
        fbPass.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: fbPass) {
            enc.setRenderPipelineState(feedbackPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            bands.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.setFragmentBuffer(history, offset: 0, index: 2)
            flatBands.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3) }
            enc.setFragmentBuffer(noteHistory, offset: 0, index: 4)
            peaks.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 5) }
            enc.setFragmentTexture(prev, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        if mode == Renderer.scopeMode { encodeScope(into: commandBuffer, target: next) }

        let postPass = MTLRenderPassDescriptor()
        postPass.colorAttachments[0].texture = target
        postPass.colorAttachments[0].loadAction = .dontCare
        postPass.colorAttachments[0].storeAction = .store
        u.resolution = SIMD2(Float(target.width), Float(target.height))
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: postPass) {
            enc.setRenderPipelineState(postPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(next, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    /// Draws the oscilloscope beam additively on top of the scene (the feedback gives phosphor persistence).
    private func encodeScope(into commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(linePipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        let aspect = u.resolution.x / u.resolution.y

        // Auto-gain so quiet and loud tracks both fill the scope.
        var peak: Float = 0
        for i in 0..<wave.count { peak = max(peak, abs(wave[i]), abs(waveRight[i])) }
        wavePeak = max(0.02, max(peak, wavePeak * 0.97))
        let gain = 1 / wavePeak

        // Ring: the waveform wrapped around a circle. Like a real scope, start on a rising zero crossing
        // so the shape holds still, smooth it across frames, and crossfade the seam closed.
        let n = 480
        let span = n * 2
        let mono = (0..<wave.count).map { (wave[$0] + waveRight[$0]) * 0.5 }
        var start = wave.count - span
        var lp: Float = 0, prevLp: Float = 0
        for i in 0..<(wave.count - span) {
            lp += (mono[i] - lp) * 0.08
            if i > 8 && prevLp < 0 && lp >= 0 { start = i; break }
            prevLp = lp
        }
        var ring = [SIMD2<Float>](repeating: .zero, count: n + 1)
        let fade = 140
        let baseR: Float = 0.5 + 0.04 * u.kick + 0.03 * u.energy
        let spin = u.phase * 0.03
        var smooth: Float = mono[start]
        for i in 0..<n {
            let a0 = start + i * 2
            smooth += (mono[a0] - smooth) * 0.5
            var s = smooth * gain
            if i >= n - fade {
                let t = Float(i - (n - fade)) / Float(fade)
                s = s * (1 - t) + scopeRing[0] * t
            }
            scopeRing[i] += (s - scopeRing[i]) * 0.35
            let a = Float(i) / Float(n) * 2 * .pi + spin
            let r = baseR + scopeRing[i] * 0.1
            ring[i] = SIMD2(cos(a) * r, sin(a) * r)
        }
        ring[n] = ring[0]
        var params = LineParams(aspect: aspect, width: 0.0065, intensity: 0.55 + 0.6 * u.level, hue: 0.3)
        enc.setVertexBytes(&params, length: MemoryLayout<LineParams>.stride, index: 1)
        enc.setFragmentBytes(&params, length: MemoryLayout<LineParams>.stride, index: 1)
        ring.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)

        // Goniometer: left/right rotated 45 degrees, so mono is a vertical line and width spreads sideways.
        let g = 256
        var gonio = [SIMD2<Float>](repeating: .zero, count: g)
        let gs = wave.count - g
        for i in 0..<g {
            let l = wave[gs + i] * gain, r = waveRight[gs + i] * gain
            gonio[i] = SIMD2((l - r) * 0.707, (l + r) * 0.707) * 0.14
        }
        params = LineParams(aspect: aspect, width: 0.0035, intensity: 0.15 + 0.15 * u.level, hue: 0.75)
        enc.setVertexBytes(&params, length: MemoryLayout<LineParams>.stride, index: 1)
        enc.setFragmentBytes(&params, length: MemoryLayout<LineParams>.stride, index: 1)
        gonio.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: g - 1)
        enc.endEncoding()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private let startTime = CACurrentMediaTime()

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 1.0 / 240), 1.0 / 20))
        lastTime = now
        update(dt: dt, time: Float(now - startTime))

        guard let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        encode(into: commandBuffer, target: drawable.texture)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Offscreen snapshot (for testing the look without audio)

    /// Accumulated GPU time of snapshot renders (for --bench).
    var gpuSeconds: Double = 0

    func snapshot(width: Int, height: Int, frames: Int, features: @escaping (Int) -> AudioFeatures) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        palette = targetPalette
        for i in 0..<frames {
            featuresProvider = { features(i) }
            update(dt: 1.0 / 60, time: Float(i) / 60)
            let cb = queue.makeCommandBuffer()!
            encode(into: cb, target: target)
            cb.commit()
            cb.waitUntilCompleted()
            gpuSeconds += cb.gpuEndTime - cb.gpuStartTime
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return ctx?.makeImage()
    }
}
