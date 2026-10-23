#!/usr/bin/env python3
# Convert one of the dnetc rc5-72 OpenCL kernels (rc5-{1,2,4}pipe.cl) to
# Metal Shading Language for compiler inspection. Keeps the kernel body
# verbatim; replaces only the vendor macro block, the kernel signature,
# get_global_id() and atomic_add(). The fourth argument picks the ROTL
# spelling (default base).
import re
import sys

src_path, dst_path, pipes = sys.argv[1], sys.argv[2], int(sys.argv[3])
variant = sys.argv[4] if len(sys.argv) > 4 else "base"   # ROTL spelling, see VARIANTS
src = open(src_path).read()

vec = "uint" if pipes == 1 else "uint%d" % pipes
lvec = "ulong" if pipes == 1 else "ulong%d" % pipes

# ROTL spellings under test. Each entry: (comment, ROTL, ROTL3, ROTL1) with
# (V) = the lane type, V( its constructor, @L( the 64-bit lane constructor. "extr" is kept as an alias of
# extr64 (the ROTL_EXTR form in the .cl files).
VARIANTS = {
  "base": ("the kernel as shipped: rotate()",
    "rotate((V)(x), (V)(s))",
    "rotate((V)(x), (V)(3u))",
    "rotate((uint)(x), (uint)(s))"),
  "extr64": ("rotate as a 64-bit funnel shift, amount (-s) & 31 (ROTL_EXTR in the .cl)",
    "V(((@L((V)(x)) << 32) | @L((V)(x))) >> @L(((V)(0u) - (V)(s)) & (V)(31u)))",
    "ROTL(x, 3u)",
    "((uint)((((ulong)(uint)(x) << 32) | (uint)(x)) >> ((0u - (uint)(s)) & 31u)))"),
  "extr64sub": ("64-bit funnel shift, amount 32 - (s & 31)",
    "V(((@L((V)(x)) << 32) | @L((V)(x))) >> @L((V)(32u) - ((V)(s) & (V)(31u))))",
    "ROTL(x, 3u)",
    "((uint)((((ulong)(uint)(x) << 32) | (uint)(x)) >> (32u - ((uint)(s) & 31u))))"),
  "astype": ("funnel shift of the value paired with itself, pair built by as_type (ROTL_EXTR in the .cl)",
    "V(as_type<@L>(PAIR) >> @L(((V)(0u) - (V)(s)) & (V)(31u)))",
    "ROTL(x, 3u)",
    "((uint)(as_type<ulong>(uint2((uint)(x), (uint)(x))) >> ((0u - (uint)(s)) & 31u)))"),
  "masked": ("rotate() with the amount masked to 5 bits first",
    "rotate((V)(x), (V)(s) & (V)(31u))",
    "rotate((V)(x), (V)(3u))",
    "rotate((uint)(x), (uint)(s) & 31u)"),
  "shifts": ("textbook shifts and or, both amounts masked (control: should fold to rotate)",
    "(((V)(x) << ((V)(s) & (V)(31u))) | ((V)(x) >> (((V)(0u) - (V)(s)) & (V)(31u))))",
    "(((V)(x) << 3) | ((V)(x) >> 29))",
    "(((uint)(x) << ((uint)(s) & 31u)) | ((uint)(x) >> ((0u - (uint)(s)) & 31u)))"),
}
VARIANTS["extr"] = VARIANTS["astype"]
if variant not in VARIANTS:
    sys.exit("unknown variant %s; one of %s" % (variant, ", ".join(sorted(VARIANTS))))
comment, rotl, rotl3, rotl1 = VARIANTS[variant]
pair = {1: "uint2((uint)(x), (uint)(x))", 2: "((uint2)(x)).xxyy", 4: "((uint4)(x)).xxyyzzww"}[pipes]
fix = lambda m: m.replace("PAIR", pair).replace("(V)", "(%s)" % vec).replace("V(", "%s(" % vec).replace("@L>", "%s>" % lvec).replace("@L(", "%s(" % lvec)

header = """/*
* Copyright distributed.net 2012-2026 - All Rights Reserved
* For use in distributed.net projects only.
* Any other distribution or use of this source violates copyright.
*
* Metal Shading Language translation of rc5-72/opencl/rc5-%dpipe.cl, used
* only to inspect what Apple's GPU compiler makes of the kernel (see
* tools/ci-bench/ci-macos-gpu.sh). Not part of the client. Keep the
* arithmetic identical to the OpenCL source.
*/
#include <metal_stdlib>
using namespace metal;

#define SWAP(x) (((uint)(x) << 24) | (((uint)(x) & 0x0000FF00u) << 8) | (((uint)(x) >> 8) & 0x0000FF00u) | ((uint)(x) >> 24))

// ROTL variant "%s": %s
#define ROTL(x, s)  %s
#define ROTL3(x)    %s
#define ROTL1(x, s) %s

""" % (pipes, variant, comment, fix(rotl), fix(rotl3), fix(rotl1))

# keep from "#define P" onward (drops the vendor-specific macro block)
body = src[src.index("#define P "):]

body = re.sub(
    r"__kernel void (\w+)\(\s*__constant const uint \*rc5_72unitwork,\s*volatile __global uint \*outbuf\)",
    r"kernel void \1(constant uint *rc5_72unitwork [[buffer(0)]],\n"
    r"                            device uint *outbuf [[buffer(1)]],\n"
    r"                            uint gid [[thread_position_in_grid]])",
    body)
body = body.replace("(uint)get_global_id(0)", "gid").replace("get_global_id(0)", "gid")
body = body.replace("atomic_add(&outbuf[0], 1)",
                    "atomic_fetch_add_explicit((device atomic_uint *)outbuf, 1u, memory_order_relaxed)")
assert "get_global_id" not in body and "atomic_add(" not in body and "__kernel" not in body

open(dst_path, "w").write(header + body)
print("wrote", dst_path)
