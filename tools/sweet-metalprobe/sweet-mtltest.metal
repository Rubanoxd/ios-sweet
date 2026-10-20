// Test kernels for sweet-mtltest (compiled to sweet-mtltest.metallib by
// build.sh with Apple's metal compiler).
#include <metal_stdlib>
using namespace metal;

// Apple's "Performing Calculations on a GPU" sample kernel.
kernel void add_arrays(device const float *inA [[buffer(0)]], device const float *inB [[buffer(1)]],
                       device float *result [[buffer(2)]], uint index [[thread_position_in_grid]])
{
    result[index] = inA[index] + inB[index];
}

// Integer arithmetic and a constant buffer.
kernel void square_add(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]],
                       constant uint &k [[buffer(2)]], uint id [[thread_position_in_grid]])
{
    out[id] = in[id] * in[id] + k;
}

// A colored triangle (render test): vertices pulled from a buffer by
// vertex_id, color interpolated to the fragment stage.
struct Vertex {
    float2 position;
    float4 color;
};
struct VOut {
    float4 position [[position]];
    float4 color;
};
vertex VOut tri_vertex(uint vid [[vertex_id]], constant Vertex *v [[buffer(0)]])
{
    VOut o;
    o.position = float4(v[vid].position, 0.0, 1.0);
    o.color = v[vid].color;
    return o;
}
fragment float4 tri_fragment(VOut in [[stage_in]])
{
    return in.color;
}

// A textured quad (texture test): xy position and uv per vertex, the
// texture sampled with a bound sampler or with a constexpr one at 60 %.
struct TOut {
    float4 position [[position]];
    float2 uv;
};
vertex TOut quad_vertex(uint vid [[vertex_id]], constant float4 *v [[buffer(0)]])
{
    TOut o;
    o.position = float4(v[vid].xy, 0.0, 1.0);
    o.uv = v[vid].zw;
    return o;
}
fragment float4 quad_fragment(TOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]])
{
    return tex.sample(s, in.uv);
}
fragment float4 quad_fragment_faded(TOut in [[stage_in]], texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv) * 0.6;
}

// Framebuffer read (programmable blending): the fragment reads the color
// already in attachment 0 and writes its inverse.
fragment float4 invert_fragment(VOut in [[stage_in]], float4 dst [[color(0)]])
{
    return float4(1.0 - dst.rgb, 1.0);
}
