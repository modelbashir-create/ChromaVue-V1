#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types

struct Vertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct Uniforms {
    // Time / animation
    float time;
    float2 resolution; // currently unused by fragment shader; kept for future effects
    
    // Visualization parameters
    int   colorMapMode;   // 0: viridis, 1: plasma, 2: heat, 3: medical
    float brightness;     // additive offset before contrast / gamma
    float contrast;       // multiplicative factor
    float gamma;          // gamma correction
    
    // Normalization range
    float minValue;
    float maxValue;
    
    // Contours
    int   contourLevels;
    int   showContours;   // treated as bool
    
    // Extra animation intensity
    float animation;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - Vertex shader

vertex VertexOut heatmap_vertex(const device Vertex* vertices [[buffer(0)]],
                                const device Uniforms& uniforms [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

// MARK: - Colormap helpers

inline float3 viridis_colormap(float t) {
    // Viridis colormap approximation
    const float3 c0 = float3(0.267004, 0.004874, 0.329415);
    const float3 c1 = float3(0.127568, 0.566949, 0.550556);
    const float3 c2 = float3(0.993248, 0.906157, 0.143936);
    
    t = saturate(t);
    return (t < 0.5)
        ? mix(c0, c1, t * 2.0)
        : mix(c1, c2, (t - 0.5) * 2.0);
}

inline float3 plasma_colormap(float t) {
    // Plasma colormap approximation
    const float3 c0 = float3(0.050383, 0.029803, 0.527975);
    const float3 c1 = float3(0.762373, 0.164384, 0.491067);
    const float3 c2 = float3(0.940015, 0.975158, 0.131326);
    
    t = saturate(t);
    return (t < 0.5)
        ? mix(c0, c1, t * 2.0)
        : mix(c1, c2, (t - 0.5) * 2.0);
}

inline float3 heat_colormap(float t) {
    // Blue → cyan → yellow → red
    t = saturate(t);
    const float3 blue   = float3(0.0, 0.0, 1.0);
    const float3 cyan   = float3(0.0, 1.0, 1.0);
    const float3 yellow = float3(1.0, 1.0, 0.0);
    const float3 red    = float3(1.0, 0.0, 0.0);
    
    if (t < 0.33) {
        return mix(blue, cyan, t * 3.0);
    } else if (t < 0.66) {
        return mix(cyan, yellow, (t - 0.33) * 3.0);
    } else {
        return mix(yellow, red, (t - 0.66) * 3.0);
    }
}

inline float3 medical_colormap(float t) {
    // Diverging blue ↔ red colormap, centered at mid-range
    // Map [0,1] to [-1,1] for symmetric behavior
    t = saturate(t * 2.0 - 1.0);
    
    if (t < 0.0) {
        // Blue range for lower side
        const float3 darkBlue  = float3(0.1, 0.25, 0.8);
        const float3 lightBlue = float3(0.3, 0.6, 1.0);
        return mix(darkBlue, lightBlue, (t + 1.0) * 0.5);
    } else {
        // Red range for upper side
        const float3 lightRed = float3(1.0, 0.5, 0.2);
        const float3 darkRed  = float3(0.85, 0.1, 0.1);
        return mix(lightRed, darkRed, t);
    }
}

inline float3 apply_colormap(float t, int mode) {
    switch (mode) {
        case 0: return viridis_colormap(t);
        case 1: return plasma_colormap(t);
        case 2: return heat_colormap(t);
        case 3: return medical_colormap(t);
        default: return viridis_colormap(t);
    }
}

// MARK: - Fragment shader

fragment float4 heatmap_fragment(VertexOut in                [[stage_in]],
                                 texture2d<float> inputTex   [[texture(0)]],
                                 const device Uniforms& uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Sample scalar (assume red channel holds the value)
    float scalar = inputTex.sample(textureSampler, in.texCoord).r;
    
    // Apply brightness, contrast, gamma
    scalar = (scalar + uniforms.brightness) * uniforms.contrast;
    scalar = pow(saturate(scalar), uniforms.gamma);
    
    // Normalize to [0,1] using min/max range
    float range = max(uniforms.maxValue - uniforms.minValue, 1e-6);
    scalar = (scalar - uniforms.minValue) / range;
    scalar = saturate(scalar);
    
    // Map scalar → color
    float3 color = apply_colormap(scalar, uniforms.colorMapMode);
    
    // Optional contour lines
    if (uniforms.showContours && uniforms.contourLevels > 0) {
        float contourStep = 1.0 / float(uniforms.contourLevels);
        float contourValue = floor(scalar / contourStep) * contourStep;
        float nextContour = contourValue + contourStep;
        
        float distToContour = min(abs(scalar - contourValue), abs(scalar - nextContour));
        const float lineWidth = 0.02;
        if (distToContour < lineWidth) {
            // Darken color near contour lines
            color = mix(color, float3(0.0, 0.0, 0.0), 0.5);
        }
    }
    
    // Optional subtle animation
    if (uniforms.animation > 0.0f) {
        float wave = sin(uniforms.time * 2.0 + length(in.texCoord - 0.5) * 10.0) * 0.1;
        color += wave * uniforms.animation;
    }
    
    return float4(color, 1.0);
}

// MARK: - Compute shader for scalar preprocessing

kernel void process_heatmap_data(texture2d<float, access::read>  inputTex  [[texture(0)]],
                                 texture2d<float, access::write> outputTex [[texture(1)]],
                                 const device Uniforms& uniforms         [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= inputTex.get_width() || gid.y >= inputTex.get_height()) {
        return;
    }
    
    float4 inputValue = inputTex.read(gid);
    float scalar = inputValue.r;
    
    // Simple edge-enhancement (Sobel-like)
    if (gid.x > 0 && gid.x < inputTex.get_width() - 1 &&
        gid.y > 0 && gid.y < inputTex.get_height() - 1) {
        
        float left   = inputTex.read(uint2(gid.x - 1, gid.y)).r;
        float right  = inputTex.read(uint2(gid.x + 1, gid.y)).r;
        float top    = inputTex.read(uint2(gid.x, gid.y - 1)).r;
        float bottom = inputTex.read(uint2(gid.x, gid.y + 1)).r;
        
        float dx = (right - left) * 0.5;
        float dy = (bottom - top) * 0.5;
        float edge = sqrt(dx * dx + dy * dy);
        
        scalar += edge * 0.1;
    }
    
    outputTex.write(float4(scalar, scalar, scalar, 1.0), gid);
}
