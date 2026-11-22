// Metal shaders, compiled at launch with makeLibrary(source:) so the Swift
// package needs no Metal build step. World space is global points, y down.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U { float2 origin; float2 size; float scale; float time; float fog; float wind; float pz; float frost; };

static inline float4 toClip(float2 p, constant U& u, float z) {
    float2 n = (p - u.origin) / u.size;
    return float4(n.x * 2.0 - 1.0, 1.0 - n.y * 2.0, z, 1.0);
}

// ---------- Particles ----------
struct P { float2 pos; float2 vel; float size; float alpha; float kind; float phase; };
struct PO { float4 position [[position]]; float2 uv; float alpha; float kind; float seed; };

vertex PO particleV(uint vid [[vertex_id]], uint iid [[instance_id]],
                    const device P* ps [[buffer(0)]], constant U& u [[buffer(1)]]) {
    P p = ps[iid];
    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    int k = int(p.kind + 0.5);
    float2 pos;
    if (k == 3) {
        // Rain: a thin streak along the velocity.
        float sp = length(p.vel);
        float2 dir = sp > 1.0 ? p.vel / sp : float2(0.0, 1.0);
        float2 perp = float2(-dir.y, dir.x);
        float len = clamp(sp * 0.021, 6.0, 32.0);
        float w = max(p.size * 0.5, 0.75 / u.scale);
        pos = p.pos + dir * (c.y * len * 0.5) + perp * (c.x * w);
    } else if (k == 7) {
        // Icicle shard: a thin spike, length in vel.x, tumbling slowly.
        float len = max(p.vel.x, 3.0);
        float w = max(p.size, 1.0 / u.scale);
        float a = p.phase;
        float2x2 R = float2x2(float2(cos(a), sin(a)), float2(-sin(a), cos(a)));
        pos = p.pos + R * float2(c.x * w, c.y * len * 0.5);
    } else if (k == 2 || k == 6) {
        // Clump: a lumpy blob that tumbles.
        float r = p.size * 1.2 + 0.5 / u.scale;
        float a = p.phase + p.pos.x * 0.03;
        float2x2 R = float2x2(float2(cos(a), sin(a)), float2(-sin(a), cos(a)));
        pos = p.pos + R * (c * r);
    } else {
        float r = p.size + 0.75 / u.scale;
        pos = p.pos + c * r;
    }
    PO o;
    o.position = toClip(pos, u, u.pz);
    o.uv = c;
    o.alpha = p.alpha;
    o.kind = p.kind;
    o.seed = fract(p.phase * 0.159);
    return o;
}

fragment float4 particleF(PO in [[stage_in]]) {
    int k = int(in.kind + 0.5);
    float a;
    float3 col = float3(1.0);
    float r = length(in.uv);
    if (k == 3) {
        float across = 1.0 - abs(in.uv.x);
        float along = smoothstep(-1.0, 0.8, in.uv.y);
        a = across * across * along * in.alpha;
        col = float3(0.80, 0.86, 0.95);
    } else if (k == 7) {
        float t = in.uv.y * 0.5 + 0.5;                 // 0 at the base, 1 at the tip
        float half_w = mix(1.0, 0.05, t);
        a = smoothstep(half_w, half_w * 0.6, abs(in.uv.x)) * in.alpha;
        col = mix(float3(0.95, 0.98, 1.0), float3(0.66, 0.84, 1.0), t) + 0.2 * smoothstep(0.3, 0.0, abs(in.uv.x + 0.35));
    } else if (k == 4 || k == 5) {
        a = smoothstep(1.0, 0.5, r) * in.alpha;
        col = mix(float3(0.95, 0.97, 1.0), float3(0.72, 0.80, 0.92), saturate(in.uv.y * 0.5 + 0.5));
    } else if (k == 2 || k == 6) {
        float ang = atan2(in.uv.y, in.uv.x);
        float edge = 0.80 + 0.12 * sin(ang * 3.0 + in.seed * 40.0) + 0.05 * sin(ang * 7.0 + in.seed * 90.0);
        a = smoothstep(edge, edge - 0.22, r) * in.alpha;
        col = mix(float3(1.0), float3(0.82, 0.87, 0.95), saturate(in.uv.y * 0.5 + 0.45));
    } else {
        // Flake: soft disc with a brighter core.
        a = (smoothstep(1.0, 0.3, r) * 0.82 + smoothstep(0.45, 0.0, r) * 0.18) * in.alpha;
    }
    return float4(col * a, a);
}

// ---------- Snow piles ----------
struct PV { float2 pos; float z; float depth; float thick; float alpha; };
struct PVO { float4 position [[position]]; float depth; float thick; float alpha; float2 world; };

vertex PVO pileV(uint vid [[vertex_id]], const device PV* vs [[buffer(0)]], constant U& u [[buffer(1)]]) {
    PV v = vs[vid];
    PVO o;
    o.position = toClip(v.pos, u, v.z);
    o.depth = v.depth;
    o.thick = v.thick;
    o.alpha = v.alpha;
    o.world = v.pos;
    return o;
}

fragment float4 pileF(PVO in [[stage_in]], constant U& u [[buffer(1)]]) {
    if (in.alpha < 0.0) {
        // Icicle: clear blue ice, brighter at the root, a glint down one side.
        float t = saturate(in.depth / max(in.thick, 0.001));
        float3 ice = mix(float3(0.93, 0.97, 1.0), float3(0.62, 0.80, 0.98), t);
        float a = (-in.alpha) * mix(0.92, 0.55, t);
        return float4(ice * a, a);
    }
    float px = 1.0 / u.scale;
    float rim = saturate(in.depth / px);                 // 1 px anti-aliased top edge
    float body = saturate(in.thick * u.scale * 0.9);     // very thin dust fades in
    float shade = saturate(in.depth / 16.0);
    float3 col = mix(float3(0.99, 0.995, 1.0), float3(0.78, 0.84, 0.94), shade * 0.8);
    // A cool shadow line right under the crust, and a few glints.
    col -= 0.05 * exp(-in.depth * 1.6) * (1.0 - rim);
    float2 g = floor(in.world * 0.8);
    float h = fract(sin(dot(g, float2(12.9898, 78.233))) * 43758.5453);
    float tw = step(0.9965, h) * (0.5 + 0.5 * sin(u.time * 2.6 + h * 60.0));
    col += tw * 0.35 * (1.0 - shade);
    float a = rim * body * in.alpha * 0.98;
    return float4(col * a, a);
}

// ---------- Depth-only occluders (windows / Dock) ----------
struct OV { float2 pos; float z; float pad; };
struct OVO { float4 position [[position]]; };
vertex OVO occV(uint vid [[vertex_id]], const device OV* vs [[buffer(0)]], constant U& u [[buffer(1)]]) {
    OVO o; o.position = toClip(vs[vid].pos, u, vs[vid].z); return o;
}

// ---------- Fog ----------
struct FO { float4 position [[position]]; float2 world; float2 uv; };
vertex FO fogV(uint vid [[vertex_id]], constant U& u [[buffer(1)]]) {
    float2 c = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? -3.0 : 1.0);
    FO o;
    o.position = float4(c, u.pz, 1.0);
    o.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    o.world = u.origin + o.uv * u.size;
    return o;
}
static inline float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 s = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), s.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), s.x), s.y);
}
fragment float4 fogF(FO in [[stage_in]], constant U& u [[buffer(1)]]) {
    float2 drift = float2(u.time * (6.0 + u.wind * 40.0), u.time * 1.5);
    float2 p = (in.world + drift) * 0.0021;
    float n = vnoise(p) * 0.55 + vnoise(p * 2.03 + 7.1) * 0.3 + vnoise(p * 4.1 + 3.3) * 0.15;
    float low = smoothstep(0.1, 1.0, in.uv.y);
    float a = u.fog * (0.10 + 0.34 * n) * (0.45 + 0.55 * low);
    float3 col = float3(0.87, 0.89, 0.93);
    return float4(col * a, a);
}

// ---------- Frost creeping in from the corners ----------
fragment float4 frostF(FO in [[stage_in]], constant U& u [[buffer(1)]]) {
    float2 uv = in.uv;
    float aspect = u.size.x / u.size.y;
    float2 q = float2(min(uv.x, 1.0 - uv.x) * aspect, min(uv.y, 1.0 - uv.y));
    float d = length(q);                                    // distance to nearest corner
    // Soft rime from the corner, broken up by fine ice-crystal grain.
    float2 p = in.world * 0.012;
    float edgeNoise = vnoise(p) * 0.6 + vnoise(p * 2.3 + 5.1) * 0.4;
    float reach = u.frost * 0.30 * (0.85 + 0.3 * edgeNoise);
    float m = smoothstep(reach, 0.0, d);
    m = m * m;
    float2 g = in.world * 0.55;
    float grain = vnoise(g) * 0.55 + vnoise(g * 2.1 + 3.7) * 0.45;   // tiny crystals
    float sparkle = smoothstep(0.86, 0.95, vnoise(in.world * 0.9 + 11.0));
    float a = m * (0.30 + 0.35 * grain + 0.35 * sparkle) * min(u.frost * 1.4, 1.0);
    float3 col = mix(float3(0.86, 0.93, 1.0), float3(1.0), grain);
    return float4(col * a, a);
}

// ---------- Truck (textured quads) ----------
struct TQ { float2 center; float2 halfSize; float angle; float flip; float alpha; float kind; };
struct TO { float4 position [[position]]; float2 uv; float alpha; float kind; float2 c; };
vertex TO truckV(uint vid [[vertex_id]], uint iid [[instance_id]],
                 const device TQ* qs [[buffer(0)]], constant U& u [[buffer(1)]]) {
    TQ q = qs[iid];
    float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 local = c * q.halfSize;
    float2x2 R = float2x2(float2(cos(q.angle), sin(q.angle)), float2(-sin(q.angle), cos(q.angle)));
    TO o;
    o.position = toClip(q.center + R * local, u, 0.0);
    float2 uv = c * 0.5 + 0.5;
    if (q.flip < 0.0) uv.x = 1.0 - uv.x;
    o.uv = uv;
    o.alpha = q.alpha;
    o.kind = q.kind;
    o.c = c;
    return o;
}
fragment float4 truckF(TO in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U& u [[buffer(1)]]) {
    int k = int(in.kind + 0.5);
    if (k == 1) {
        // Beacon glow: a rotating amber flash.
        float r = length(in.c);
        float pulse = pow(0.5 + 0.5 * sin(u.time * 9.0), 3.0);
        float a = smoothstep(1.0, 0.0, r) * (0.15 + 0.6 * pulse) * in.alpha;
        float3 col = float3(1.0, 0.62, 0.12);
        return float4(col * a, a);
    }
    if (k == 2) {
        // Soft contact shadow.
        float r = length(in.c);
        float a = smoothstep(1.0, 0.2, r) * 0.28 * in.alpha;
        return float4(0.0, 0.0, 0.0, a);
    }
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float4 t = tex.sample(s, in.uv);
    return t * in.alpha;
}
"""
