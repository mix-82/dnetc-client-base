#!/usr/bin/env python3
"""Test only: apply the V3D "ror" change to a Mesa source tree.
usage: apply-ror.py <mesa source dir>
Fails if any of the three places it edits does not look as expected."""
import sys, os

root = sys.argv[1]

def edit(rel, anchor, new, after=True):
    path = os.path.join(root, rel)
    src = open(path).read()
    if src.count(anchor) != 1:
        sys.exit("%s: expected exactly one match of the anchor, found %d" % (rel, src.count(anchor)))
    if not os.path.exists(path + ".orig"):
        open(path + ".orig", "w").write(src)
    src = src.replace(anchor, anchor + new if after else new + anchor)
    open(path, "w").write(src)
    print("edited", rel)

edit("src/broadcom/compiler/nir_to_vir.c",
     """        case nir_op_ishl:
                result = vir_SHL(c, src[0], src[1]);
                break;
""",
     """        case nir_op_uror:
                result = vir_ROR(c, src[0], src[1]);
                break;
        case nir_op_urol:
                /* A left rotate is a right rotate by the negated amount. For
                 * a constant amount pick the equivalent value that fits a
                 * small immediate.
                 */
                if (nir_src_is_const(instr->src[1].src)) {
                        uint32_t n = nir_src_comp_as_uint(instr->src[1].src,
                                                          instr->src[1].swizzle[0]) & 31;
                        result = vir_ROR(c, src[0],
                                         vir_uniform_ui(c, n > 16 ? 32 - n : -n));
                } else {
                        result = vir_ROR(c, src[0], vir_NEG(c, src[1]));
                }
                break;
""")
edit("src/gallium/drivers/v3d/v3d_screen.c",
     "                .lower_fdiv = true,\n", "                .has_rotate32 = true,\n", after=False)
edit("src/broadcom/vulkan/v3dv_pipeline.c",
     "      .lower_fdiv = true,\n", "      .has_rotate32 = true,\n", after=False)
