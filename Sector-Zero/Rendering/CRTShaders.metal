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
    constexpr sampler frameSampler(address::clamp_to_edge, filter::linear);

    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float2 fbSize = uniforms.frameBufferSize;

    // Sharp bilinear: snap to texel centers and blend only across the width
    // of one display pixel, so glyphs stay crisp with softly rounded edges
    // instead of the shimmer of nearest or the smear of plain linear.
    float2 texel = uv * fbSize;
    float2 texelCenter = floor(texel - 0.5) + 0.5;
    float2 pixelFootprint = max(fwidth(texel), 0.0001);
    float2 sharpTexel = texelCenter + clamp((texel - texelCenter) / pixelFootprint, 0.0, 1.0);
    float2 sharpUV = sharpTexel / fbSize;

    float3 frameColor = frameTexture.sample(frameSampler, sharpUV).rgb;

    // Phosphor glow: a wide cross of cheap linear taps approximates the halo
    // a bright glyph carves into the tube face. Sampled un-sharpened so the
    // halo spreads smoothly past glyph edges.
    float2 texelSize = 1.0 / fbSize;
    float3 glow = float3(0.0);
    glow += frameTexture.sample(frameSampler, uv + float2( texelSize.x, 0.0)).rgb;
    glow += frameTexture.sample(frameSampler, uv - float2( texelSize.x, 0.0)).rgb;
    glow += frameTexture.sample(frameSampler, uv + float2(0.0,  texelSize.y)).rgb;
    glow += frameTexture.sample(frameSampler, uv - float2(0.0,  texelSize.y)).rgb;
    glow += frameTexture.sample(frameSampler, uv + texelSize * float2( 1.7,  1.7)).rgb;
    glow += frameTexture.sample(frameSampler, uv + texelSize * float2(-1.7,  1.7)).rgb;
    glow += frameTexture.sample(frameSampler, uv + texelSize * float2( 1.7, -1.7)).rgb;
    glow += frameTexture.sample(frameSampler, uv + texelSize * float2(-1.7, -1.7)).rgb;
    glow *= 0.125;

    // Scanlines follow framebuffer rows (not device pixels), with a gaussian
    // beam profile, and fade out as rows approach one device pixel so high
    // scaling never produces moiré or a uniformly dark screen.
    float rowsPerDevicePixel = fbSize.y / max(uniforms.viewportSize.y, 1.0);
    float scanStrength = 0.32 * smoothstep(0.55, 0.18, rowsPerDevicePixel);
    float beamOffset = fract(texel.y) - 0.5;
    float beam = exp(-beamOffset * beamOffset * 7.0);
    float scanline = 1.0 - scanStrength * (1.0 - beam);

    // Gentle shading toward the edges — presence, not darkness.
    float2 centered = uv - 0.5;
    float vignette = 1.0 - 0.16 * smoothstep(0.25, 0.72, length(centered));

    float edgeDistance = max(abs(centered.x), abs(centered.y)) * 2.0;
    float cornerMask = smoothstep(1.02, 0.98, edgeDistance);

    // The beam dims glyph bodies row-by-row, but the halo lives in the
    // phosphor coating and bridges the gaps between scanlines.
    float glowLuminance = dot(glow, float3(0.30, 0.55, 0.15));
    float3 phosphorTint = float3(0.62, 1.0, 0.72);
    float3 idleGlow = float3(0.006, 0.014, 0.009);

    float3 color = frameColor * scanline
                 + glow * phosphorTint * 0.28
                 + phosphorTint * glowLuminance * glowLuminance * 0.10
                 + idleGlow;
    color *= vignette * cornerMask;

    return float4(color, 1.0);
}
