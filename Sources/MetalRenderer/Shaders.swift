//  Shaders.swift — the two shaders, as source, compiled when the first pane
//  opens.
//
//  Compiled at runtime rather than shipped as a metallib on purpose: a
//  SwiftPM resource bundle is one more thing that can be missing from an app
//  bundle at the worst moment, and a terminal that cannot find its shader is a
//  terminal that cannot draw. The cost is one compile of a few hundred bytes,
//  once per process, cached below.

import Metal

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float4 rect;    // x, y, width, height in device pixels, y down
        float4 uv;      // u0, v0, u1, v1 in the atlas
        float4 colour;  // straight (non-premultiplied) rgba
        uint4  flags;   // .x: 0 solid, 1 coverage mask, 2 coloured glyph
    };

    struct Uniforms {
        float2 viewport;
        // Stroke weight. CoreText drawn onto an opaque background comes out a
        // touch lighter than a coverage mask blended straight, so the mask is
        // raised to this power before it is used: above 1 thins the text,
        // below 1 fattens it. The value is measured, not chosen (F3).
        float textGamma;
        float pad;
    };

    struct Varying {
        float4 position [[position]];
        float2 uv;
        float4 colour;
        uint   flags [[flat]];
        float  gamma [[flat]];
    };

    vertex Varying cell_vertex(uint vertexID [[vertex_id]],
                               uint instanceID [[instance_id]],
                               const device Instance *instances [[buffer(0)]],
                               constant Uniforms &uniforms [[buffer(1)]]) {
        const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 corner = corners[vertexID];
        Instance instance = instances[instanceID];
        float2 pixel = instance.rect.xy + corner * instance.rect.zw;
        Varying out;
        out.position = float4(pixel.x / uniforms.viewport.x * 2.0 - 1.0,
                              1.0 - pixel.y / uniforms.viewport.y * 2.0, 0.0, 1.0);
        out.uv = mix(instance.uv.xy, instance.uv.zw, corner);
        out.colour = instance.colour;
        out.flags = instance.flags.x;
        out.gamma = uniforms.textGamma;
        return out;
    }

    fragment float4 cell_fragment(Varying in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  sampler atlasSampler [[sampler(0)]]) {
        // Everything leaves here premultiplied, because the pipeline blends
        // with (one, one - source alpha).
        if (in.flags == 0u) {
            return float4(in.colour.rgb * in.colour.a, in.colour.a);
        }
        float4 texel = atlas.sample(atlasSampler, in.uv);
        if (in.flags == 2u) {
            return texel * in.colour.a;         // an emoji is already its colour
        }
        float coverage = pow(texel.a, in.gamma) * in.colour.a;
        return float4(in.colour.rgb * coverage, coverage);
    }
    """

    // Compiling is per-device and happens on the main thread, where every
    // pane is created.
    @MainActor private static var cache: [ObjectIdentifier: MTLLibrary] = [:]

    @MainActor
    static func library(for device: MTLDevice) throws -> MTLLibrary {
        let key = ObjectIdentifier(device)
        if let found = cache[key] { return found }
        let library = try device.makeLibrary(source: source, options: nil)
        cache[key] = library
        return library
    }
}
