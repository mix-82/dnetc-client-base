#!/usr/bin/env python3
# Writes a SPIR-V binary as a C++ array of 32-bit words, for embedding a
# compute shader in the client.
#
#   spv2cpp.py <in.spv> <array name> <source file name> <out.cpp>

import struct
import sys


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: spv2cpp.py <in.spv> <array name> <source file name> <out.cpp>")
    spv_path, array_name, source_name, out_path = sys.argv[1:5]

    data = open(spv_path, "rb").read()
    if len(data) < 20 or len(data) % 4 != 0:
        sys.exit("%s: not a SPIR-V file (size %d)" % (spv_path, len(data)))
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    if words[0] != 0x07230203:
        sys.exit("%s: wrong SPIR-V magic number 0x%08x" % (spv_path, words[0]))

    lines = []
    lines.append("/*")
    lines.append(" * Copyright distributed.net 2012-2026 - All Rights Reserved")
    lines.append(" * For use in distributed.net projects only.")
    lines.append(" * Any other distribution or use of this source violates copyright.")
    lines.append(" *")
    lines.append(" * Generated from %s by tools/build_shader.sh. Do not edit." % source_name)
    lines.append("*/")
    lines.append("")
    lines.append("static const u32 %s[] =" % array_name)
    lines.append("{")
    for i in range(0, len(words), 6):
        row = ", ".join("0x%08x" % w for w in words[i:i + 6])
        if i + 6 < len(words):
            row += ","
        lines.append("  " + row)
    lines.append("};")
    lines.append("")
    open(out_path, "w").write("\n".join(lines))


main()
