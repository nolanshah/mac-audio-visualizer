// Compiled at runtime with MTLDevice.makeLibrary(source:) so no Xcode Metal toolchain is needed.
enum Shaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 c0; float4 c1; float4 c2; float4 c3;
    float2 resolution;
    float time; float phase;
    float bass; float mid; float treble; float level;
    float beat; float hit; float mode; float beatCount;
    float kick; float frameScale; float intensity; float beatStrength;
    float historyHead; float historyFrac; float beatPhase; float beatTravel;
    float vocal; float energy; float noteHead; float noteFrac;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ---------- helpers ----------

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    float2x2 m = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
    for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = m * p; a *= 0.5; }
    return v;
}

// Cheaper 3-octave fbm for per-line wiggles where detail is invisible.
float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    float2x2 m = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p = m * p; a *= 0.5; }
    return v / 0.875;
}

float2 rot(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// Cyclic gradient through the 4 palette colors (album art or preset).
float3 pal(float t, constant Uniforms& u) {
    t = fract(t) * 4.0;
    float f = smoothstep(0.0, 1.0, fract(t));
    int i = int(t);
    float3 a, b;
    if (i == 0)      { a = u.c0.rgb; b = u.c1.rgb; }
    else if (i == 1) { a = u.c1.rgb; b = u.c2.rgb; }
    else if (i == 2) { a = u.c2.rgb; b = u.c3.rgb; }
    else             { a = u.c3.rgb; b = u.c0.rgb; }
    return mix(a, b, f);
}

float band(constant float* b, float x) {
    float fi = clamp(x, 0.0, 1.0) * 63.0;
    int i = int(fi);
    return mix(b[i], b[min(i + 1, 63)], fract(fi));
}

// Sparse twinkling stars driven by hi-hats / treble; drawn in post so they stay crisp.
float3 sparkle(float2 p, constant Uniforms& u) {
    float3 acc = 0.0;
    for (int layer = 0; layer < 2; layer++) {
        float scale = 18.0 + 14.0 * float(layer);
        float2 g = p * scale + float2(17.0 * float(layer), 0.0);
        float2 id = floor(g);
        float epoch = floor(u.time * 3.0 + hash21(id) * 3.0);
        float h = hash21(id + epoch * 13.7);
        float life = fract(u.time * 3.0 + hash21(id) * 3.0);
        float2 off = float2(hash21(id + 3.1), hash21(id + 7.7)) - 0.5;
        float r = length(fract(g) - 0.5 - off * 0.6);
        float thr = 0.993 - 0.008 * u.treble;
        float st = step(thr, h) * exp(-r * r * 450.0) * sin(life * M_PI_F);
        acc += mix(pal(h * 5.0, u), float3(1.0), 0.6) * st;
    }
    return acc * (0.25 + 0.6 * u.treble + 1.2 * u.hit);
}

// ---------- scenes ----------

// 0: domain-warped silk with a spectrum halo and beat shockwaves.
float3 silk(float2 p, constant Uniforms& u, constant float* bands) {
    float t = u.phase * 0.08;
    float2 q = float2(fbm(p * 1.0 + float2(0.0, t)), fbm(p * 1.0 + float2(5.2, 1.3) - t));
    float2 r = float2(fbm(p * 1.3 + 2.6 * q + float2(1.7, 9.2) + 0.2 * t),
                      fbm(p * 1.3 + 2.6 * q + float2(8.3, 2.8) - 0.15 * t));
    float warp = 1.9 + 0.9 * u.level;               // slow energy only: no per-hit jolts
    float f = fbm(p * 1.1 + warp * r);

    float3 col = pal(f * 1.1 + length(q) * 0.5 + u.time * 0.012, u);
    col *= 0.12 + 1.5 * f * f * (0.5 + 0.6 * u.level);
    float ridge = pow(1.0 - abs(sin(f * 9.0 + u.phase * 0.25)), 10.0);
    col += ridge * pal(f + 0.5, u) * (0.1 + 0.5 * u.mid);

    float rad = length(p);
    float a01 = atan2(abs(p.x), -p.y) / M_PI_F;   // 0 at bottom (bass) -> 1 at top (treble)
    float s = band(bands, a01 * 0.92);
    float R = 0.40 + 0.05 * u.bass + 0.03 * u.kick;
    col *= mix(0.3, 1.0, smoothstep(R - 0.1, R + 0.15, rad));
    float d = rad - (R + 0.18 * s);
    float halo = 0.005 / (abs(d) + 0.005);
    col += halo * pal(a01 * 0.6 + u.time * 0.03, u) * (0.35 + 1.2 * s) * 0.45;
    col += pal(0.55, u) * (0.01 + 0.04 * u.bass) / (rad + 0.06);

    // One ripple per beat: born on the beat, reaches the edge as the next beat arrives.
    float bp = u.beatPhase;
    float swR = R + (1.0 - pow(1.0 - bp, 2.5)) * 1.5;
    float fadeR = pow(1.0 - bp, 1.6) * u.beatStrength;
    col += pal(0.7, u) * exp(-abs(rad - swR) * 22.0) * fadeR * 0.6;
    return col;
}

// 1: flying through a nebula tunnel; rings rush past on the kick.
float3 tunnel(float2 p, constant Uniforms& u, constant float* bands) {
    p = rot(p, u.phase * 0.04);
    float rad = length(p);
    float ang = atan2(p.y, p.x);
    float z = 0.35 / (rad + 0.02) + u.phase * 0.12 + u.beatTravel / 1.5;
    float2 cs = float2(cos(ang), sin(ang));
    float n = fbm(cs * 1.8 + float2(z * 0.9, -z * 0.6));
    float n2 = fbm(cs * 3.5 - float2(z * 1.7, z * 0.4) + n * 2.0);
    float a01 = atan2(abs(p.x), -p.y) / M_PI_F;
    float s = band(bands, a01 * 0.92);

    float3 col = pal(n2 * 0.9 + z * 0.04 + u.time * 0.01, u) * (0.04 + 2.6 * n2 * n2 * n2);
    float rings = pow(0.5 + 0.5 * cos(z * 6.2831 * 1.5), 14.0);
    col += rings * pal(z * 0.03 + 0.4, u) * (0.25 + 0.6 * u.bass + 0.5 * s + 0.6 * u.kick);
    col *= smoothstep(0.0, 0.45, rad) * (0.55 + 0.8 * u.level);
    col += pal(0.55, u) * (0.02 + 0.1 * u.bass) / (rad + 0.08) * 0.5;
    col += pal(a01 + 0.2, u) * s * s * smoothstep(0.6, 1.5, rad) * 0.7;
    return col;
}

// 2: luminous ribbons, one per frequency region, breathing with the spectrum.
float3 ribbons(float2 p, constant Uniforms& u, constant float* bands) {
    float3 col = pal(fbm(p * 0.7 + u.phase * 0.04) * 0.5, u) * 0.1;
    const int N = 14;
    for (int i = 0; i < N; i++) {
        float fi = float(i) / float(N - 1);
        float s = band(bands, 0.04 + fi * 0.85);
        float y0 = (fi - 0.5) * 1.25;
        float x = p.x;
        float w = sin(x * (1.4 + fi * 1.8) + u.phase * (0.5 + fi * 0.8) + fi * 7.0) * (0.03 + 0.2 * s)
                + (fbm3(float2(x * 1.2 + u.phase * 0.25, fi * 9.0)) - 0.5) * (0.12 + 0.35 * u.bass);
        float d = abs(p.y - y0 - w);
        float th = 0.0025 + 0.005 * s;
        float g = pow(th / (d + th), 1.6);
        float fade = smoothstep(2.0, 0.4, abs(x));
        col += pal(fi * 0.7 + 0.25 + u.time * 0.02, u) * g * fade * (0.3 + 1.3 * s);
    }
    // The voice: a warm, brighter ribbon through the middle that only appears when someone sings.
    float vw = sin(p.x * 2.1 + u.phase * 0.7) * (0.04 + 0.16 * u.vocal)
             + (fbm3(float2(p.x * 1.6 - u.phase * 0.3, 3.3)) - 0.5) * 0.2 * u.vocal;
    float vd = abs(p.y - 0.02 - vw);
    float vth = 0.003 + 0.006 * u.vocal;
    float vg = pow(vth / (vd + vth), 1.5) * smoothstep(2.0, 0.4, abs(p.x));
    col += mix(pal(0.9, u), float3(1.0, 0.94, 0.86), 0.5) * vg * u.vocal * 1.6;
    return col;
}

// 3: aurora curtains folding over the sky; each curtain's height follows a band.
float3 aurora(float2 p, constant Uniforms& u, constant float* bands) {
    float3 col = mix(pal(0.0, u) * 0.12, pal(0.05, u) * 0.03, smoothstep(-1.0, 1.0, p.y));
    const int N = 5;
    for (int i = 0; i < N; i++) {
        float fi = float(i) / float(N - 1);
        float s = band(bands, 0.06 + fi * 0.7);
        float x = p.x * (0.9 + 0.15 * fi) + fi * 3.7;
        float yb = -0.55 + 0.32 * fi
                 + (fbm3(float2(x * 0.55 + u.phase * 0.07, fi * 5.0)) - 0.5) * 0.9
                 + sin(x * 1.2 + u.phase * 0.25 + fi * 2.0) * (0.06 + 0.1 * u.bass);
        float dy = p.y - yb;
        float rays = fbm(float2(x * 7.0 + u.phase * 0.15, u.phase * 0.12 + fi * 11.0));
        rays = pow(rays, 2.2) * 2.2;
        float h = 0.25 + 0.55 * s + 0.25 * u.bass + (i == 2 ? 0.45 * u.vocal : 0.0);
        float curtain = smoothstep(-0.015, 0.03, dy) * exp(-max(dy, 0.0) / h * 2.2);
        float edge = exp(-abs(dy) * 70.0);
        float3 c = pal(0.3 + fi * 0.18 + clamp(dy, 0.0, 1.0) * 0.55 + u.time * 0.01, u);
        col += c * (curtain * rays * 0.55 + edge * 0.35) * (0.3 + 0.9 * s);
    }
    return col;
}

// 4: topographic isolines over slowly drifting terrain; lines step gently on the beat, each lit by a band.
float3 contours(float2 p, constant Uniforms& u, constant float* bands) {
    float t = u.phase * 0.02;
    float2 q = p * 0.7;
    float2 w = float2(fbm(q + float2(t, 1.7)), fbm(q + float2(4.1, -t)));
    float h = fbm(q * 0.9 + w * 0.9 + float2(0.0, t * 0.5));
    float rad = length(p);
    h += (0.08 * u.energy + 0.04 * u.kick) * exp(-rad * rad * 2.0);

    const float K = 10.0;
    float v = h * K - u.beatTravel * 0.25 - u.phase * 0.01;
    float id = floor(v + 0.5);
    float d = abs(v - id);
    float fw = max(fwidth(v), 1e-4);
    float s = band(bands, fract(id * 0.618));
    float line = smoothstep(1.0 + 1.2 * s, 0.2, d / fw);
    float glow = exp(-d * 7.0) * s * 0.22;
    float major = fmod(abs(id), 4.0) < 0.5 ? 1.0 : 0.0;

    float3 col = pal(h * 0.6 + 0.1, u) * 0.06 * (0.4 + h);
    float3 lc = pal(fract(id * 0.071) + u.time * 0.01, u);
    col += lc * (line * (0.3 + 0.3 * major + 0.9 * s) + glow);
    return col;
}

// 5: ribbons wrapped into concentric rings that breathe with the spectrum.
float3 halo(float2 p, constant Uniforms& u, constant float* bands) {
    p *= 1.0 - 0.06 * u.kick;
    float rad = length(p);
    float ang = atan2(p.y, p.x);
    float2 cs = float2(cos(ang), sin(ang));
    float3 col = pal(0.0, u) * 0.08 + pal(0.55, u) * 0.03 / (rad + 0.2);
    col += mix(pal(0.9, u), float3(1.0, 0.94, 0.86), 0.4) * u.vocal * 0.05 / (rad + 0.04);
    const int N = 13;
    for (int i = 0; i < N; i++) {
        float fi = float(i) / float(N - 1);
        float s = band(bands, 0.04 + fi * 0.85);
        float r0 = 0.16 + fi * 0.62;
        float k = float(3 + i % 4);
        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float w = sin(ang * k + dir * u.phase * (0.3 + fi * 0.5) + fi * 5.0) * (0.008 + 0.06 * s)
                + (fbm3(cs * 1.6 + float2(u.phase * 0.18, fi * 7.0)) - 0.5) * (0.04 + 0.12 * u.bass);
        float d = abs(rad - r0 - w);
        float th = 0.0022 + 0.0045 * s;
        float g = pow(th / (d + th), 1.6);
        col += pal(fi * 0.7 + 0.25 + u.time * 0.02, u) * g * (0.3 + 1.3 * s);
    }
    return col;
}

float historyBand(constant float* hist, int row, float x) {
    float fi = clamp(x, 0.0, 1.0) * 63.0;
    int i = int(fi);
    constant float* r = hist + row * 64;
    return mix(r[i], r[min(i + 1, 63)], fract(fi));
}

// 6: Unknown Pleasures-style ridgelines; each line is a past moment receding into the distance.
float3 ridgeline(float2 p, constant Uniforms& u, constant float* hist) {
    const int N = 40;
    float aspect = u.resolution.x / u.resolution.y;
    float W = min(aspect * 0.62, 1.05);
    float px = 2.0 / u.resolution.y;
    int head = int(u.historyHead + 0.5);
    float3 col = pal(0.0, u) * 0.05;
    for (int i = 0; i < N; i++) {
        float fi = (float(i) + u.historyFrac) / float(N);      // 0 = front, 1 = back
        float persp = 1.0 - 0.4 * fi;
        float base = -0.82 + 1.5 * pow(fi, 0.9);
        float xs = p.x / (W * persp);
        float ax = abs(xs);
        float extent = smoothstep(1.08, 1.0, ax);
        int row = (head + i) % N;
        float s = historyBand(hist, row, ax * 0.8);
        float env = smoothstep(1.0, 0.2, ax);
        float jag = (vnoise(float2(xs * 22.0, float(row) * 3.1)) - 0.5) * 0.35 * s;
        float h = max(0.0, s * s + jag) * env * 0.33 * persp;
        float d = p.y - (base + h);
        float th = (0.0014 + 0.0025 * s) * persp;
        float line = smoothstep(th + px, th * 0.3, abs(d)) * extent;
        float glow = exp(-abs(d) * 80.0) * 0.18 * extent * s;
        float fade = (1.0 - fi * 0.8) * smoothstep(1.0, 0.92, fi);
        col += pal(0.3 + fi * 0.45 + u.time * 0.01, u) * (line + glow) * fade * (0.55 + 1.1 * s);
        if (d < 0.0 && extent > 0.5) break;   // nearer ridge hides everything behind it
    }
    return col;
}

// 7: out-of-focus lights. Far/small = treble, mid = mids, near/big = bass, each orb on its own band
// (normalized per band so every range shows). Hi-hats flicker the far layer; the voice adds a warm glow.
float3 bokeh(float2 p, constant Uniforms& u, constant float* flat) {
    float3 col = mix(pal(0.0, u) * 0.18, pal(0.1, u) * 0.06, smoothstep(-1.2, 1.2, p.y + p.x * 0.3));
    col += pal(0.85, u) * u.vocal * 0.22 * exp(-dot(p, p) * 1.2);
    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer) / 3.0;                 // 0 = far (treble) ... 1 = near (bass)
        float lo = mix(0.68, 0.0, fl), hi = mix(1.0, 0.22, fl);
        float scale = mix(6.0, 1.9, fl);
        float2 g = p * scale + float2(u.phase * (0.04 + 0.1 * fl) + fl * 13.0, -u.phase * (0.025 + 0.04 * fl));
        float2 id = floor(g);
        float2 f = fract(g) - 0.5;
        float h = hash21(id + fl * 31.0);
        if (h < mix(0.6, 0.5, fl)) continue;
        float s = band(flat, mix(lo, hi, hash21(id + 5.3)));
        s = s * s;
        float r = mix(0.1, 0.33, pow(hash21(id + 9.1), 1.5)) * (1.0 + 0.3 * s + 0.2 * u.kick * fl);
        float2 off = (float2(hash21(id + 1.7), hash21(id + 2.9)) - 0.5) * (0.9 - 2.0 * r);
        float d = length(f - off);
        float soft = mix(0.05, 0.22, fl);
        float disc = smoothstep(r, r - soft * r * 2.0, d);
        float rim = smoothstep(r, r - 0.06 * r, d) * (1.0 - smoothstep(r - 0.06 * r, r - 0.3 * r, d));
        float flick = (1.0 - fl) * u.hit * step(0.8, hash21(id + floor(u.time * 4.0)));
        float a = (disc * 0.45 + rim * 0.3) * (0.06 + 1.5 * s + flick + 0.25 * u.beat * fl) * mix(0.6, 1.0, fl);
        col += pal(h * 2.3 + fl * 0.25 + u.time * 0.01, u) * a;
    }
    return col;
}

// 8: liquid-metal body with satellite droplets that orbit, stretch and merge back in.
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float blobSDF(float3 q, constant Uniforms& u, constant float* bands) {
    float t = u.phase * 0.3;
    float d = length(q) - (0.55 + 0.1 * u.kick + 0.06 * u.energy);
    d -= sin(q.x * 3.5 + t * 1.3) * sin(q.y * 3.9 - t) * sin(q.z * 3.7 + t * 0.7) * (0.06 + 0.16 * u.bass);
    float drive[4] = { u.bass, u.mid, u.treble, u.vocal };
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float a = t * (0.5 + 0.17 * fi) + fi * 1.5708;
        float orbit = 0.62 + 0.22 * sin(t * 0.37 + fi * 2.1) + 0.25 * drive[i];
        float3 c = float3(cos(a) * orbit, sin(a * 1.3 + fi) * 0.42, sin(a) * orbit);
        float r = 0.17 + 0.13 * drive[i];
        d = smin(d, length(q - c) - r, 0.32);
    }
    return d * 0.8;
}

float3 chromeEnv(float3 r, constant Uniforms& u) {
    float y = r.y;
    float3 skyTop = mix(float3(0.9), pal(0.5 + u.time * 0.01, u), 0.4);
    float3 sky = mix(float3(0.03), skyTop, smoothstep(-0.15, 0.85, y));
    float3 ground = mix(float3(0.01), pal(0.0, u) * 0.6, smoothstep(-1.0, -0.2, y));
    float3 c = mix(ground, sky, smoothstep(-0.2, 0.15, y));
    float key = pow(max(dot(r, normalize(float3(0.5, 0.8, 0.3))), 0.0), 50.0);
    float strip = smoothstep(0.9, 0.97, max(dot(r, normalize(float3(-0.7, 0.35, 0.5))), 0.0));
    c += float3(1.0) * key * 2.5;
    c += pal(0.7, u) * strip * 1.5;
    c += pal(0.35, u) * pow(max(dot(r, normalize(float3(0.2, -0.3, -1.0))), 0.0), 6.0) * 0.9;
    return c;
}

float3 chrome(float2 p, constant Uniforms& u, constant float* bands) {
    float3 ro = float3(0.0, 0.0, 2.6);
    float3 rd = normalize(float3(p, -1.7));
    float a = u.phase * 0.08, b = sin(u.phase * 0.05) * 0.5;
    float2 xz = rot(float2(ro.x, ro.z), a); ro = float3(xz.x, ro.y, xz.y);
    float2 dxz = rot(float2(rd.x, rd.z), a); rd = float3(dxz.x, rd.y, dxz.y);
    float2 yz = rot(float2(ro.y, ro.z), b); ro = float3(ro.x, yz.x, yz.y);
    float2 dyz = rot(float2(rd.y, rd.z), b); rd = float3(rd.x, dyz.x, dyz.y);

    float3 col = pal(0.0, u) * 0.12 + pal(0.55, u) * (0.04 + 0.1 * u.bass) / (length(p) + 0.4);
    float t = 0.0;
    bool hit = false;
    for (int i = 0; i < 72; i++) {
        float d = blobSDF(ro + rd * t, u, bands);
        if (d < 0.001) { hit = true; break; }
        t += d;
        if (t > 6.0) break;
    }
    if (hit) {
        float3 q = ro + rd * t;
        float2 e = float2(0.002, 0.0);
        float3 n = normalize(float3(blobSDF(q + e.xyy, u, bands) - blobSDF(q - e.xyy, u, bands),
                                    blobSDF(q + e.yxy, u, bands) - blobSDF(q - e.yxy, u, bands),
                                    blobSDF(q + e.yyx, u, bands) - blobSDF(q - e.yyx, u, bands)));
        float3 r = reflect(rd, n);
        float fres = pow(1.0 - max(dot(-rd, n), 0.0), 4.0);
        col = chromeEnv(r, u) * (0.75 + 0.4 * fres) + pal(0.6, u) * fres * (0.2 + 0.5 * u.bass);
    }
    return col;
}

// 9: eight-way mirrored mandala; it turns a notch and breathes outward on each beat.
float3 kaleidoscope(float2 p, constant Uniforms& u, constant float* bands) {
    p *= 1.0 - 0.05 * u.kick;
    float rad = length(p);
    float seg = 6.2831853 / 8.0;
    float ang = atan2(p.y, p.x) + u.beatTravel * seg * 0.125 + u.time * 0.01;
    ang = ang - seg * floor(ang / seg);
    ang = abs(ang - seg * 0.5);
    float2 q = float2(cos(ang), sin(ang)) * rad;
    q = q * 1.4 - float2(u.beatTravel * 0.06 + u.time * 0.02, 0.0);
    float f = fbm(q * 1.5 + fbm(q * 2.2 + u.time * 0.03) * 1.6);
    float s = band(bands, clamp(rad * 0.6, 0.0, 1.0));
    float lines = pow(1.0 - abs(sin(f * 16.0 + rad * 5.0 - u.beatTravel * 0.8)), 18.0);
    float rings = pow(0.5 + 0.5 * cos(rad * 22.0 - u.beatTravel * 3.14159), 30.0) * smoothstep(1.4, 0.2, rad);
    float3 col = pal(f * 1.3 + rad * 0.2 + u.time * 0.015, u) * pow(f, 2.2) * (0.5 + 1.4 * s);
    col += lines * pal(f + 0.45, u) * (0.3 + 0.8 * u.mid);
    col += rings * pal(0.8 + rad * 0.2, u) * (0.12 + 0.5 * u.kick);
    col += pal(0.65, u) * (0.02 + 0.06 * u.energy) / (rad + 0.05);
    return col;
}

// 10: piano keyboard with a rising piano roll of detected notes; sung (center-panned) notes glow warm white.
float3 keys(float2 p, constant Uniforms& u, constant float* roll) {
    float aspect = u.resolution.x / u.resolution.y;
    float W = aspect * 0.94;
    float ww = 2.0 * W / 36.0;                     // 36 white keys = C2..C7
    float kbTop = -0.6, kbBot = -0.9;
    float px = 2.0 / u.resolution.y;
    float3 col = mix(pal(0.0, u) * 0.12, pal(0.0, u) * 0.03, smoothstep(-1.0, 1.0, p.y));

    float x = p.x + W;
    if (x < 0.0 || x > 2.0 * W || p.y < kbBot - 0.02) return col;
    float wf = x / ww;
    int wi = min(int(wf), 35);
    float fx = wf - float(wi);
    int deg = wi % 7, oct = wi / 7;
    const int semis[7] = { 0, 2, 4, 5, 7, 9, 11 };
    const int blackRight[7] = { 1, 1, 0, 1, 1, 1, 0 };
    int white = oct * 12 + semis[deg];
    int black = -1;
    float bx = 0.0;                                  // position across the black key, -1..1
    if (fx > 0.7 && blackRight[deg] == 1 && wi < 35) { black = white + 1; bx = (fx - 1.0) / 0.3; }
    if (fx < 0.3 && wi > 0 && blackRight[(deg + 6) % 7] == 1) { black = white - 1; bx = fx / 0.3; }

    int head = int(u.noteHead + 0.5);
    float rowH = (1.0 - kbTop) / 128.0;

    if (p.y > kbTop) {
        // Piano roll column for this x.
        int note = -1;
        float across = 0.0;
        if (black >= 0) { note = black; across = abs(bx); }
        else if (abs(fx - 0.5) < 0.3) { note = white; across = abs(fx - 0.5) / 0.3; }
        float age = (p.y - kbTop) / (1.0 - kbTop);
        float rowF = (p.y - kbTop) / rowH - u.noteFrac;
        int row = clamp(int(rowF), 0, 127);
        if (note >= 0 && note < 61) {
            int idx = ((head + row) % 128) * 128 + note * 2;
            float e = roll[idx], v = roll[idx + 1];
            float on = smoothstep(0.35, 0.65, e);
            float edge = smoothstep(1.0, 0.75, across);
            float3 nc = pal(float(note % 12) / 12.0 * 0.85 + 0.15, u);
            nc = mix(nc, float3(1.0, 0.93, 0.85) * 1.4, smoothstep(0.15, 0.45, v));
            float fade = pow(1.0 - age, 1.4);
            col += nc * on * edge * fade * (0.6 + 0.8 * e);
            col += nc * on * fade * exp(-across * 2.5) * 0.18;
        }
        // Faint octave guides at each C.
        if (deg == 0) col += pal(0.5, u) * 0.03 * smoothstep(2.0 * px, 0.0, fx * ww) * (1.0 - age);
        // Glow line along the top of the keyboard.
        col += pal(0.55, u) * exp(-(p.y - kbTop) * 60.0) * (0.15 + 0.5 * u.level);
        return col;
    }

    // Keyboard: lit keys glow in their pitch color.
    float yk = (p.y - kbBot) / (kbTop - kbBot);      // 0 bottom .. 1 top
    int cur = (head % 128) * 128;
    bool onBlack = black >= 0 && yk > 0.38;
    int note = onBlack ? black : white;
    float e = smoothstep(0.3, 0.6, roll[cur + note * 2]);
    float v = smoothstep(0.15, 0.45, roll[cur + note * 2 + 1]);
    float3 lit = mix(pal(float(note % 12) / 12.0 * 0.85 + 0.15, u), float3(1.0, 0.93, 0.85), v);
    if (onBlack) {
        float3 base = float3(0.025) + pal(0.0, u) * 0.1;
        col = mix(base, lit * 1.2, e) * (0.85 + 0.15 * yk);
    } else {
        float gap = smoothstep(0.0, 2.0 * px / ww, min(fx, 1.0 - fx));
        float3 base = mix(float3(0.06), float3(0.16), yk) + pal(0.5, u) * 0.03;
        col = mix(base, lit * 1.1, e) * gap;
    }
    col *= smoothstep(kbBot - 0.01, kbBot + 0.02, p.y);
    return col;
}

float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// 11: modern spectrum bars: glassy pills, falling peak caps and a mirrored floor reflection.
float3 bars(float2 p, constant Uniforms& u, constant float* flat, constant float* peaks) {
    float aspect = u.resolution.x / u.resolution.y;
    const float N = 48.0;
    float W = min(aspect * 0.86, 1.55);
    float floorY = -0.3;
    float px = 2.0 / u.resolution.y;
    float3 col = pal(0.0, u) * 0.08;
    col += pal(0.5, u) * 0.07 * exp(-abs(p.y - floorY) * 3.0) * (0.4 + u.energy);

    float x = (p.x + W) / (2.0 * W);
    if (x < 0.0 || x > 1.0) return col;
    float slot = 2.0 * W / N;
    float bi = min(floor(x * N), N - 1.0);
    float bx = (fract(x * N) - 0.5) * slot;
    float t = (bi + 0.5) / N;
    float v = band(flat, t * 0.97);
    v = v * v * (3.0 - 2.0 * v);
    float pk = band(peaks, t * 0.97);
    float hw = slot * 0.33;
    float maxH = 0.95;

    bool reflected = p.y < floorY;
    float y = abs(p.y - floorY);
    float h = 0.02 + v * maxH;
    float sd = sdRoundBox(float2(bx, y - h * 0.5), float2(hw, h * 0.5), hw);
    float soft = reflected ? px * 6.0 : px;
    float body = smoothstep(soft, -soft, sd);
    float3 c = pal(0.2 + y * 0.45 + t * 0.25 + u.time * 0.01, u);
    float sheen = smoothstep(-hw, -hw * 0.3, bx) * smoothstep(-hw * 0.1, -hw * 0.5, bx) * 0.5;
    float3 barCol = c * (0.55 + 0.6 * y / maxH) + sheen * 0.5;
    float glow = exp(-max(sd, 0.0) * 35.0) * 0.25 * (0.3 + v);

    float capY = 0.02 + pk * maxH + 0.025;
    float capSd = sdRoundBox(float2(bx, y - capY), float2(hw, 0.006), 0.006);
    float cap = smoothstep(soft, -soft, capSd);
    float3 capCol = mix(c, float3(1.0), 0.6) * 1.3;

    float3 bar = barCol * body + c * glow + capCol * cap;
    if (reflected) bar *= 0.22 * exp(-y * 3.5);
    return col + bar;
}

// 12: oscilloscope backdrop (graticule + glow); the beam itself is drawn by lineVert/lineFrag.
float3 scope(float2 p, constant Uniforms& u) {
    float rad = length(p);
    float px = 2.0 / u.resolution.y;
    float3 col = pal(0.0, u) * 0.07;
    float rings = 0.0;
    for (int i = 1; i <= 4; i++) rings += smoothstep(1.5 * px, 0.0, abs(rad - 0.22 * float(i)));
    float cross = smoothstep(1.2 * px, 0.0, min(abs(p.x), abs(p.y))) * smoothstep(0.95, 0.2, rad);
    col += pal(0.45, u) * (rings + cross) * 0.05;
    col += pal(0.55, u) * (0.03 + 0.08 * u.energy) * exp(-rad * rad * 3.0);
    return col;
}

// ---------- oscilloscope beam ----------

struct LineParams { float aspect; float width; float intensity; float hue; };
struct LineOut { float4 pos [[position]]; float across; float along; };

vertex LineOut lineVert(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant float2* pts [[buffer(0)]],
                        constant LineParams& lp [[buffer(1)]]) {
    float2 a = pts[iid], b = pts[iid + 1];
    float2 dir = b - a;
    float len = length(dir);
    dir = len > 1e-6 ? dir / len : float2(1.0, 0.0);
    float2 n = float2(-dir.y, dir.x);
    const float2 corners[6] = { float2(0, -1), float2(1, -1), float2(0, 1), float2(0, 1), float2(1, -1), float2(1, 1) };
    float2 c = corners[vid];
    float2 pos = mix(a, b, c.x) + n * c.y * lp.width + dir * (c.x * 2.0 - 1.0) * lp.width;
    LineOut o;
    o.pos = float4(pos.x / lp.aspect, pos.y, 0.0, 1.0);
    o.across = c.y;
    o.along = float(iid);
    return o;
}

fragment float4 lineFrag(LineOut in [[stage_in]],
                         constant LineParams& lp [[buffer(1)]],
                         constant Uniforms& u [[buffer(2)]]) {
    float core = exp(-in.across * in.across * 6.0);
    float3 c = pal(lp.hue + in.along * 0.0008 + u.time * 0.02, u);
    c = mix(c, float3(1.0), core * core * 0.5);
    return float4(c * core * lp.intensity * u.intensity, 0.0);
}

// ---------- passes ----------

// Renders the scene and blends it over a zoomed, rotated copy of the previous frame (trails).
fragment float4 feedbackFrag(VOut in [[stage_in]],
                             constant Uniforms& u [[buffer(0)]],
                             constant float* bands [[buffer(1)]],
                             constant float* hist [[buffer(2)]],
                             constant float* flat [[buffer(3)]],
                             constant float* roll [[buffer(4)]],
                             constant float* peaks [[buffer(5)]],
                             texture2d<float> prev [[texture(0)]],
                             sampler smp [[sampler(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = (in.uv - 0.5) * 2.0;
    p.x *= aspect;
    p.y = -p.y;
    p *= 1.0 - 0.025 * u.kick;

    int mode = int(u.mode + 0.5);
    float3 scene;
    float fb;
    if (mode == 0)      { scene = silk(p, u, bands);    fb = 0.80; }
    else if (mode == 1) { scene = tunnel(p, u, bands);  fb = 0.80; }
    else if (mode == 2) { scene = ribbons(p, u, bands);      fb = 0.87; }
    else if (mode == 3) { scene = aurora(p, u, bands);       fb = 0.86; }
    else if (mode == 4) { scene = contours(p, u, bands);     fb = 0.25; }
    else if (mode == 5) { scene = halo(p, u, bands);         fb = 0.86; }
    else if (mode == 6) { scene = ridgeline(p, u, hist);     fb = 0.2; }
    else if (mode == 7) { scene = bokeh(p, u, flat);         fb = 0.45; }
    else if (mode == 8) { scene = chrome(p, u, bands);       fb = 0.3; }
    else if (mode == 9) { scene = kaleidoscope(p, u, bands); fb = 0.75; }
    else if (mode == 10) { scene = keys(p, u, roll);         fb = 0.0; }
    else if (mode == 11) { scene = bars(p, u, flat, peaks);  fb = 0.35; }
    else                 { scene = scope(p, u);              fb = 0.6; }
    scene *= u.intensity;

    float2 c = in.uv - 0.5;
    c.x *= aspect;
    float zoom = 0.994 - 0.008 * u.bass - 0.012 * u.kick;
    c = rot(c, 0.003 * sin(u.phase * 0.21)) * zoom;
    c.x /= aspect;
    float3 prevc = prev.sample(smp, c + 0.5).rgb;
    float3 col = max(scene, prevc * pow(fb, u.frameScale));
    return float4(col, 1.0);
}

float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

// Chromatic aberration, bloom, beat flash, vignette, tonemap and film grain.
fragment float4 postFrag(VOut in [[stage_in]],
                         constant Uniforms& u [[buffer(0)]],
                         texture2d<float> src [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float2 d = uv - 0.5;
    float aspect = u.resolution.x / u.resolution.y;
    float ca = 0.002 + 0.012 * u.beat;
    float3 col;
    col.r = src.sample(smp, uv - d * ca).r;
    col.g = src.sample(smp, uv).g;
    col.b = src.sample(smp, uv + d * ca).b;

    float3 bl = 0.0;
    float2 px = float2(1.0 / aspect, 1.0) / 900.0;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 2.39996;
        float r = 5.0 + float(i) * 5.0;
        bl += src.sample(smp, uv + float2(cos(a), sin(a)) * r * px).rgb;
    }
    bl /= 8.0;
    col += max(bl - 0.3, 0.0) * (0.7 + 0.6 * u.bass);

    float2 sp = d * 2.0;
    sp.x *= aspect;
    sp.y = -sp.y;
    col += sparkle(sp, u) * u.intensity;

    col *= 1.0 + 0.15 * u.beat;
    float vig = smoothstep(1.4, 0.2, length(d * float2(aspect, 1.0) * 1.1));
    col *= mix(0.45, 1.0, vig);
    col = aces(col * 1.1);
    col += (hash21(uv * u.resolution + fract(u.time * 7.13) * 91.0) - 0.5) * 0.03;
    return float4(saturate(col), 1.0);
}
"""#
}
