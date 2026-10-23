#!/usr/bin/env python3
# Convert one of the dnetc rc5-72 OpenCL kernels (rc5-{1,2,4}pipe.cl) to
# Metal Shading Language for compiler inspection. Keeps the kernel body
# verbatim; replaces only the vendor macro block, the kernel signature,
# get_global_id() and atomic_add().
import re
import sys

src_path, dst_path, pipes = sys.argv[1], sys.argv[2], int(sys.argv[3])
src = open(src_path).read()

vec = "uint" if pipes == 1 else "uint%d" % pipes
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

#define ROTL(x, s)  rotate((%s)(x), (%s)(s))
#define ROTL3(x)    rotate((%s)(x), (%s)(3u))
#define ROTL1(x, s) rotate((uint)(x), (uint)(s))
#define SWAP(x) (((uint)(x) << 24) | (((uint)(x) & 0x0000FF00u) << 8) | (((uint)(x) >> 8) & 0x0000FF00u) | ((uint)(x) >> 24))

""" % (pipes, vec, vec, vec, vec)

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
