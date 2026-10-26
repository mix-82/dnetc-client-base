// Probe: does Apple's OpenCL front end accept inline GCN assembly, and does
// the AMD back end assemble it? rotate_asm uses v_alignbit_b32 directly
// (alignbit masks its amount to 5 bits, so no separate "and 31" is needed);
// rotate_ref is the plain rotate() for comparison. Both must give the same
// results; the dumpcl + disassembly shows which instructions each became.
// Apple's front end only knows generic constraints ("=v"/"v" are rejected as
// invalid), so "r" is used and the back end has to map it to a VGPR.
#define ROTL_ASM(x, s) ({ \
    uint _x = (uint)(x), _s = 32u - (uint)(s), _res; \
    __asm__("v_alignbit_b32 %0, %1, %1, %2" : "=r"(_res) : "r"(_x), "r"(_s)); \
    _res; \
})

__kernel void rotate_asm(__global const uint *a, __global const uint *s, __global uint *out)
{
  uint i = get_global_id(0);
  uint x = a[i];
  uint t = s[i];
  int n;
  for (n = 0; n < 16; n++)
  {
    x = ROTL_ASM(x + t, t);
    t += x;
  }
  out[i] = x;
}

__kernel void rotate_ref(__global const uint *a, __global const uint *s, __global uint *out)
{
  uint i = get_global_id(0);
  uint x = a[i];
  uint t = s[i];
  int n;
  for (n = 0; n < 16; n++)
  {
    x = rotate(x + t, t);
    t += x;
  }
  out[i] = x;
}
