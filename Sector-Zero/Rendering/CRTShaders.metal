//
//  CRTShaders.metal
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct CRTUniforms {
    float2 viewportSize;
    float2 frameBufferSize;
    float time;
};

vertex VertexOut crtVertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = (positions[vertexID] + 1.0) * 0.5;
    return out;
}

fragment float4 crtFragment(VertexOut in [[stage_in]],
                            constant CRTUniforms &uniforms [[buffer(0)]],
                            texture2d<float> frameTexture [[texture(0)]]) {
    constexpr sampler frameSampler(address::clamp_to_edge, filter::nearest);

    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float2 pixel = uv * uniforms.viewportSize;
    float3 frameColor = frameTexture.sample(frameSampler, uv).rgb;

    float luminance = max(max(frameColor.r, frameColor.g), frameColor.b);
    float scanline = 0.70 + 0.30 * sin(pixel.y * 3.14159265);

    float2 centered = uv - 0.5;
    float vignette = smoothstep(0.80, 0.24, length(centered * float2(1.02, 1.34)));

    float edgeDistance = max(abs(centered.x) / 0.5, abs(centered.y) / 0.5);
    float cornerMask = smoothstep(1.02, 0.96, edgeDistance);

    float phosphorBloom = 0.055 * luminance;
    float3 phosphor = frameColor * (1.0 + phosphorBloom) + float3(0.03, 0.22, 0.08) * phosphorBloom;
    float3 idleGlow = float3(0.004, 0.010, 0.006);

    float3 color = (idleGlow + phosphor) * scanline * vignette * cornerMask;
    return float4(color, 1.0);
}
