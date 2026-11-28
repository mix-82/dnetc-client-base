#!/bin/sh
# Compiles one GLSL compute shader to SPIR-V and writes the C++ file that
# embeds it. Needs glslang on the PATH (Khronos glslang, "glslang-tools").
#
#   tools/build_shader.sh <name>      e.g.  tools/build_shader.sh rc5-ref
#
# Reads <name>.comp, writes <name>.spv (not committed) and <name>.cpp with
# the array vk_<name with - as _>_spv, e.g. vk_rc5_ref_spv.

set -e
name="$1"
if [ -z "$name" ] || [ ! -f "$name.comp" ]; then
  echo "usage: tools/build_shader.sh <name>   (needs <name>.comp)" >&2
  exit 1
fi
here=`dirname "$0"`
array="vk_`echo "$name" | tr '-' '_'`_spv"

glslang -V --target-env vulkan1.2 --quiet -o "$name.spv" "$name.comp"
python3 "$here/spv2cpp.py" "$name.spv" "$array" "$name.comp" "$name.cpp"
echo "$name.comp -> $name.cpp ($array)"
