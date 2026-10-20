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
