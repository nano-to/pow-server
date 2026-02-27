#include <metal_stdlib>
using namespace metal;

// Blake2b constants
constant ulong blake2b_iv[8] = {
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
    0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
};

constant uint sigma[160] = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3,
    11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4,
    7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8,
    9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13,
    2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9,
    12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11,
    13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10,
    6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5,
    10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0
};

ulong rotr64(ulong x, uint n) {
    return (x >> n) | (x << (64 - n));
}

void G(thread ulong* v, uint a, uint b, uint c, uint d, ulong x, ulong y) {
    v[a] = v[a] + v[b] + x;
    v[d] = rotr64(v[d] ^ v[a], 32);
    v[c] = v[c] + v[d];
    v[b] = rotr64(v[b] ^ v[c], 24);
    v[a] = v[a] + v[b] + y;
    v[d] = rotr64(v[d] ^ v[a], 16);
    v[c] = v[c] + v[d];
    v[b] = rotr64(v[b] ^ v[c], 63);
}

kernel void blake2b_pow(
    constant ulong& start_work [[buffer(0)]],
    device const uint8_t* block_hash [[buffer(1)]],
    device ulong* hash_results [[buffer(2)]],
    device uint* valid_indices [[buffer(3)]],
    device atomic_uint* valid_count [[buffer(4)]],
    constant uint& count [[buffer(5)]],
    constant ulong& threshold [[buffer(6)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= count) {
        return;
    }
    ulong work = start_work + index;
    
    // Prepare message: work (8 bytes BE) || block_hash (32 bytes) = 40 bytes
    thread ulong m[16] = {0};
    
    // Work in little-endian (as required by Nano PoW)
    m[0] = work;
    
    // Block hash (32 bytes = 4 uint64) - load little-endian words
    for (uint i = 0; i < 4; i++) {
        ulong val = 0;
        for (uint j = 0; j < 8; j++) {
            val |= (ulong(block_hash[i * 8 + j]) << (j * 8));
        }
        m[i + 1] = val;
    }
    
    // Initialize h
    thread ulong h[8];
    h[0] = blake2b_iv[0] ^ 0x01010008;
    for (uint i = 1; i < 8; i++) {
        h[i] = blake2b_iv[i];
    }
    
    // Compression with unrolled rounds (12 rounds)
    thread ulong v[16];
    v[0] = h[0]; v[1] = h[1]; v[2] = h[2]; v[3] = h[3];
    v[4] = h[4]; v[5] = h[5]; v[6] = h[6]; v[7] = h[7];
    v[8] = blake2b_iv[0]; v[9] = blake2b_iv[1];
    v[10] = blake2b_iv[2]; v[11] = blake2b_iv[3];
    v[12] = blake2b_iv[4] ^ 40;
    v[13] = blake2b_iv[5];
    v[14] = blake2b_iv[6] ^ 0xFFFFFFFFFFFFFFFF;
    v[15] = blake2b_iv[7];
    
    for (uint round = 0; round < 12; round++) {
        uint base = (round % 10) * 16;
        G(v, 0, 4, 8, 12, m[sigma[base + 0]], m[sigma[base + 1]]);
        G(v, 1, 5, 9, 13, m[sigma[base + 2]], m[sigma[base + 3]]);
        G(v, 2, 6, 10, 14, m[sigma[base + 4]], m[sigma[base + 5]]);
        G(v, 3, 7, 11, 15, m[sigma[base + 6]], m[sigma[base + 7]]);
        G(v, 0, 5, 10, 15, m[sigma[base + 8]], m[sigma[base + 9]]);
        G(v, 1, 6, 11, 12, m[sigma[base + 10]], m[sigma[base + 11]]);
        G(v, 2, 7, 8, 13, m[sigma[base + 12]], m[sigma[base + 13]]);
        G(v, 3, 4, 9, 14, m[sigma[base + 14]], m[sigma[base + 15]]);
    }
    
    for (uint i = 0; i < 8; i++) {
        h[i] ^= v[i] ^ v[i + 8];
    }
    
    hash_results[index] = h[0];
    // Check threshold using first 8 bytes (little-endian h[0])
    if (h[0] >= threshold) {
        uint old_count = atomic_fetch_add_explicit(valid_count, 1, memory_order_relaxed);
        if (old_count < 1024) {
            valid_indices[old_count] = index;
        }
    }
}
