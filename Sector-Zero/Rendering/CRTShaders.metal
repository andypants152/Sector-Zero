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
                            constant CRTUniforms &uniforms [[buffer(0)]]) {
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float2 pixel = uv * uniforms.viewportSize;

    float3 baseColor = float3(0.004, 0.009, 0.006);
    float scanline = 0.72 + 0.28 * sin(pixel.y * 3.14159265);

    float2 centered = uv - 0.5;
    float vignette = smoothstep(0.86, 0.22, length(centered * float2(1.05, 1.35)));

    float glow = exp(-length((uv - float2(0.18, 0.16)) * float2(5.0, 3.4))) * 0.07;
    float3 phosphor = float3(0.05, 0.55, 0.28) * glow;

    float2 cursorOrigin = float2(38.0, 36.0);
    float2 cursorSize = float2(12.0, 18.0);
    float2 cursorMax = cursorOrigin + cursorSize;
    bool insideCursor = pixel.x >= cursorOrigin.x && pixel.x <= cursorMax.x &&
                        pixel.y >= cursorOrigin.y && pixel.y <= cursorMax.y;
    float cursorBlink = smoothstep(0.34, 0.64, 0.5 + 0.5 * sin(uniforms.time * 5.2));
    float3 cursorColor = insideCursor ? float3(0.16, 0.95, 0.48) * cursorBlink : float3(0.0);

    float3 color = (baseColor + phosphor + cursorColor) * scanline * vignette;
    return float4(color, 1.0);
}
