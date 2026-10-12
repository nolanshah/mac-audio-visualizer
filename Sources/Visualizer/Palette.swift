import AppKit
import simd

struct Palette {
    let name: String
    let colors: [SIMD4<Float>]

    init(_ name: String, _ hex: [UInt32]) {
        self.name = name
        colors = hex.map { Palette.rgb($0) }
    }

    init(name: String, colors: [SIMD4<Float>]) {
        self.name = name
        self.colors = colors
    }

    static func rgb(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
    }

    // Order matters: dark -> mid -> bright -> accent, cycled smoothly in the shader.
    static let presets: [Palette] = [
        Palette("Dusk", [0x14072E, 0xB5179E, 0xFFB86B, 0x5A2A9C]),
        Palette("Deep Sea", [0x020A1F, 0x0077B6, 0x9BF6FF, 0x1B3B8C]),
        Palette("Ember", [0x120303, 0x9D0208, 0xFFBA08, 0xE85D04]),
        Palette("Synthwave", [0x0B0223, 0xFF2A8A, 0x2DE2E6, 0x7B2FF7]),
        Palette("Moss", [0x050F0A, 0x2D6A4F, 0xE9F5DB, 0x95D5B2]),
        Palette("Pearl", [0x0C0C10, 0x6C6F7D, 0xF4F1EA, 0xB7A6D9]),
    ]

    /// Pulls 4 representative colors out of album artwork with a tiny k-means.
    static func fromArtwork(_ image: NSImage) -> Palette? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        var points: [SIMD3<Float>] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Float(pixels[i]) / 255, g = Float(pixels[i + 1]) / 255, b = Float(pixels[i + 2]) / 255
            points.append(SIMD3<Float>(r, g, b))
        }
        let lum: (SIMD3<Float>) -> Float = { simd_dot($0, SIMD3<Float>(0.2126, 0.7152, 0.0722)) }
        let sorted = points.sorted { lum($0) < lum($1) }
        let k = 6
        var centers: [SIMD3<Float>] = []
        for c in 0..<k {
            let idx: Int = (c * 2 + 1) * sorted.count / (2 * k)
            centers.append(sorted[min(sorted.count - 1, idx)])
        }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0..<10 {
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            counts = [Int](repeating: 0, count: k)
            for p in points {
                var best = 0, bestD = Float.greatestFiniteMagnitude
                for c in 0..<k {
                    let d = simd_distance_squared(p, centers[c])
                    if d < bestD { bestD = d; best = c }
                }
                sums[best] += p; counts[best] += 1
            }
            for c in 0..<k where counts[c] > 0 { centers[c] = sums[c] / Float(counts[c]) }
        }

        // Prefer populous and colorful clusters.
        func saturation(_ c: SIMD3<Float>) -> Float {
            let mx = c.max(), mn = c.min()
            return mx > 0 ? (mx - mn) / mx : 0
        }
        func score(_ c: Int) -> Float { Float(counts[c]) * (0.3 + saturation(centers[c])) }
        let ranked = (0..<k).filter { counts[$0] > 0 }.sorted { score($0) > score($1) }
        var chosen = Array(ranked.prefix(4)).map { centers[$0] }
        while chosen.count < 4 { chosen.append(chosen.last ?? SIMD3(0.5, 0.5, 0.5)) }

        // Stylize: richer saturation, a deep shadow tone and a luminous highlight.
        func stylize(_ c: SIMD3<Float>, brightness: Float) -> SIMD4<Float> {
            let ns = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let out = NSColor(hue: h, saturation: min(1, s * 1.35 + 0.08), brightness: CGFloat(brightness), alpha: 1)
                .usingColorSpace(.sRGB)!
            return SIMD4(Float(out.redComponent), Float(out.greenComponent), Float(out.blueComponent), 1)
        }
        let byLum = chosen.sorted { lum($0) < lum($1) }
        return Palette(name: "Album", colors: [
            stylize(byLum[0], brightness: 0.14),
            stylize(byLum[1], brightness: 0.7),
            stylize(byLum[3], brightness: 1.0),
            stylize(byLum[2], brightness: 0.55),
        ])
    }
}
