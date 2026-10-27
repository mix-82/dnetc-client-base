#!/usr/bin/env python3
# Probe kernels for Apple's GPU compiler: which source operations does it
# lower to the funnel shift (AGX extr, AMD v_alignbit_b32), and with an
# immediate or a register amount? Each probe is one tiny Metal kernel that
# reads x, y, z from a buffer (so nothing folds to a constant) and stores
# its result. Writes one <dir>/probe-<name>.metal per probe and an index
# <dir>/probes.txt (name<TAB>description).
#
# usage: extr_probes.py <dir>
import os
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

# (name, description, body); x, y, z are uint; s = y & 31 is a variable
# amount in range; store the result in o[i] (or o[2*i], o[2*i+1] for two)
P = [
  # 32-bit rotates
  ("rot_const", "rotate(x, 3)", "o[i] = rotate(x, 3u);"),
  ("rot_var", "rotate(x, y)", "o[i] = rotate(x, y);"),
  ("rot_var_masked", "rotate(x, y & 31)", "o[i] = rotate(x, s);"),
  ("rot_var_mod", "rotate(x, y % 32)", "o[i] = rotate(x, y % 32u);"),
  ("rot_right_var", "rotate(x, -y) (rotate right)", "o[i] = rotate(x, 0u - y);"),
  ("rot_shifts", "(x << s) | (x >> (32 - s)) with s = y & 31", "o[i] = (x << s) | (x >> ((32u - s) & 31u));"),
  ("rot_shifts_neg", "(x << s) | (x >> (-s & 31))", "o[i] = (x << s) | (x >> ((0u - s) & 31u));"),
  ("rot_shifts_or1", "(x << s) | ((x >> 1) >> (31 - s))", "o[i] = (x << s) | ((x >> 1u) >> (31u - s));"),
  ("rot_select0", "s == 0 ? x : (x << s) | (x >> (32 - s))", "o[i] = s == 0u ? x : ((x << s) | (x >> (32u - s)));"),
  # 64-bit pair forms of a 32-bit rotate or funnel shift
  ("pair_shr_var", "(uint)(as_type<ulong>(uint2(x, x)) >> ((-y) & 31))  [the branch's ROTL]",
   "o[i] = (uint)(as_type<ulong>(uint2(x, x)) >> ((0u - y) & 31u));"),
  ("pair_shr_var63", "(uint)(as_type<ulong>(uint2(x, x)) >> (y & 63))", "o[i] = (uint)(as_type<ulong>(uint2(x, x)) >> (y & 63u));"),
  ("pair_shr_32sub", "(uint)(as_type<ulong>(uint2(x, x)) >> (32 - s))", "o[i] = (uint)(as_type<ulong>(uint2(x, x)) >> (32u - s));"),
  ("pair_shr_const", "(uint)(as_type<ulong>(uint2(x, x)) >> 29)", "o[i] = (uint)(as_type<ulong>(uint2(x, x)) >> 29u);"),
  ("funnel_r_var", "(uint)(as_type<ulong>(uint2(z, x)) >> s)  [general right funnel]", "o[i] = (uint)(as_type<ulong>(uint2(z, x)) >> s);"),
  ("funnel_r_const", "(uint)(as_type<ulong>(uint2(z, x)) >> 13)", "o[i] = (uint)(as_type<ulong>(uint2(z, x)) >> 13u);"),
  ("funnel_l_var", "(uint)((as_type<ulong>(uint2(z, x)) << s) >> 32)  [left funnel]", "o[i] = (uint)((as_type<ulong>(uint2(z, x)) << s) >> 32);"),
  ("funnel_l_const", "(uint)((as_type<ulong>(uint2(z, x)) << 13) >> 32)", "o[i] = (uint)((as_type<ulong>(uint2(z, x)) << 13) >> 32);"),
  ("funnel_explicit", "(uint)((((ulong)x << 32) | z) >> s)", "o[i] = (uint)((((ulong)x << 32) | (ulong)z) >> s);"),
  ("funnel_shifts", "(z >> s) | (x << (32 - s)), s in 1..31", "uint t = s | 1u; o[i] = (z >> t) | (x << (32u - t));"),
  # full 64-bit shifts and rotates
  ("u64_shr_var", "ulong >> (y & 63), both halves", "ulong u = as_type<ulong>(uint2(x, z)) >> (y & 63u); o[2*i] = (uint)u; o[2*i+1] = (uint)(u >> 32);"),
  ("u64_shl_var", "ulong << (y & 63), both halves", "ulong u = as_type<ulong>(uint2(x, z)) << (y & 63u); o[2*i] = (uint)u; o[2*i+1] = (uint)(u >> 32);"),
  ("s64_shr_var", "long >> (y & 63) (arithmetic)", "long l = as_type<long>(uint2(x, z)) >> (y & 63u); o[2*i] = (uint)l; o[2*i+1] = (uint)(l >> 32);"),
  ("u64_shr_const", "ulong >> 13, both halves", "ulong u = as_type<ulong>(uint2(x, z)) >> 13; o[2*i] = (uint)u; o[2*i+1] = (uint)(u >> 32);"),
  ("u64_rot_var", "rotate(ulong, y)", "ulong u = rotate(as_type<ulong>(uint2(x, z)), (ulong)y); o[2*i] = (uint)u; o[2*i+1] = (uint)(u >> 32);"),
  ("u64_rot_const", "rotate(ulong, 13)", "ulong u = rotate(as_type<ulong>(uint2(x, z)), 13ul); o[2*i] = (uint)u; o[2*i+1] = (uint)(u >> 32);"),
  # 32-bit shifts and bitfields
  ("shr_var", "x >> (y & 31)", "o[i] = x >> s;"),
  ("shl_var", "x << (y & 31)", "o[i] = x << s;"),
  ("shr_var_nomask", "x >> y", "o[i] = x >> y;"),
  ("bfe_var", "(x >> s) & 0xFF", "o[i] = (x >> s) & 0xFFu;"),
  ("extract_bits_var", "extract_bits(x, y & 15, 8)", "o[i] = extract_bits(x, y & 15u, 8u);"),
  ("extract_bits_const", "extract_bits(x, 5, 8)", "o[i] = extract_bits(x, 5u, 8u);"),
  ("insert_bits_var", "insert_bits(x, z, y & 15, 8)", "o[i] = insert_bits(x, z, y & 15u, 8u);"),
  ("insert_bits_const", "insert_bits(x, z, 5, 8)", "o[i] = insert_bits(x, z, 5u, 8u);"),
  ("extract_across", "16 bits from bit 24 of the pair (x, z)", "o[i] = (uint)(as_type<ulong>(uint2(x, z)) >> 24) & 0xFFFFu;"),
  # byte and halfword shuffles
  ("bswap_shifts", "byte swap with shifts and masks", "o[i] = (x << 24) | ((x & 0xFF00u) << 8) | ((x >> 8) & 0xFF00u) | (x >> 24);"),
  ("bswap_uchar4", "as_type<uint>(as_type<uchar4>(x).wzyx)", "o[i] = as_type<uint>(as_type<uchar4>(x).wzyx);"),
  ("half_swap", "as_type<uint>(as_type<ushort2>(x).yx)", "o[i] = as_type<uint>(as_type<ushort2>(x).yx);"),
  ("half_mix", "low half of z, high half of x", "o[i] = as_type<uint>(ushort2(as_type<ushort2>(z).x, as_type<ushort2>(x).y));"),
  ("byte_mix", "uchar4(x.y, z.x, x.w, z.z)", "uchar4 a = as_type<uchar4>(x), b = as_type<uchar4>(z); o[i] = as_type<uint>(uchar4(a.y, b.x, a.w, b.z));"),
  ("reverse_bits", "reverse_bits(x)", "o[i] = reverse_bits(x);"),
  # narrow and vector rotates
  ("rot16_var", "rotate(ushort, ushort) on both halves", "ushort2 h = as_type<ushort2>(x), k = as_type<ushort2>(y); o[i] = as_type<uint>(rotate(h, k));"),
  ("rot_v2_var", "rotate(uint2, uint2)", "uint2 r = rotate(uint2(x, z), uint2(y, y + 1u)); o[2*i] = r.x; o[2*i+1] = r.y;"),
  ("pair_v2_var", "the branch's 2-pipe ROTL form",
   "uint2 v = uint2(x, z); uint2 r = uint2(as_type<ulong2>(v.xxyy) >> ulong2((uint2(0u) - uint2(y, y + 1u)) & uint2(31u))); o[2*i] = r.x; o[2*i+1] = r.y;"),
]

HEAD = """#include <metal_stdlib>
using namespace metal;

// %s
kernel void probe(device const uint *a [[buffer(0)]], device uint *o [[buffer(1)]],
                  uint i [[thread_position_in_grid]])
{
  uint x = a[3 * i], y = a[3 * i + 1], z = a[3 * i + 2];
  uint s = y & 31u;
  %s
}
"""

with open(os.path.join(out, "probes.txt"), "w") as idx:
    for name, desc, body in P:
        with open(os.path.join(out, "probe-%s.metal" % name), "w") as f:
            f.write(HEAD % (desc, body))
        idx.write("%s\t%s\n" % (name, desc))
print("%d probes in %s" % (len(P), out))
