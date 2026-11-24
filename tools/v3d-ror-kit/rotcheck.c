/*
 * Test only (not for a pull request): check 32-bit rotates done by an OpenCL
 * device against the same rotates done on the CPU.
 *
 * Kernels:
 *   var_l  rotate(x, s)                       left, variable amount
 *   var_r  (x >> s) | (x << (32u - s))        right, variable amount
 *   var_c  (x << s) | (x >> (32u - s))        left, variable amount, spelled out
 *   cl_N   rotate(x, N)                       left, constant N = 1..31
 *   cr_N   (x >> N) | (x << (32u - N))        right, constant N = 1..31
 *
 * OpenCL C takes shift amounts modulo 32, so every amount is defined.
 *
 * Environment:
 *   ROTCHECK_EXPECT=<text>   stop unless the device name contains <text>
 *   ROTCHECK_ONLY=var        run only the three variable-amount kernels
 *   ROTCHECK_CONTROL=1       compare against a deliberately wrong reference
 *                            (the check must then report mismatches)
 *   ROTCHECK_COMPILE_ONLY=1  only make the driver compile the variable-amount
 *                            kernels (for drivers that cannot execute, such
 *                            as Mesa's drm-shim); no results are checked
 * Exit: 0 all match, 1 mismatches, 2 OpenCL error, 3 wrong device.
 */
#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#define NX 256
#define NS 256
#define ITEMS (NX * NS)

static int control;

static uint32_t rotl(uint32_t x, uint32_t s) { s &= 31; return s ? (x << s) | (x >> (32 - s)) : x; }
static uint32_t rotr(uint32_t x, uint32_t s) { return rotl(x, 32 - (s & 31)); }

static uint32_t rnd_state = 0x2545F491u;
static uint32_t rnd(void)
{
  rnd_state ^= rnd_state << 13; rnd_state ^= rnd_state >> 17; rnd_state ^= rnd_state << 5;
  return rnd_state;
}

#define CHK(e) do { cl_int _e = (e); if (_e != CL_SUCCESS) { \
  printf("OPENCL ERROR %d at %s\n", (int)_e, #e); return 2; } } while (0)

static void show_library(void)
{
  FILE *f = fopen("/proc/self/maps", "r");
  char line[1024], last[1024] = "";
  if (!f) return;
  while (fgets(line, sizeof(line), f)) {
    char *p = strstr(line, "/");
    if (p && strstr(p, "Rusticl") && strcmp(p, last)) {
      printf("library: %s", p);
      strncpy(last, p, sizeof(last) - 1);
    }
  }
  fclose(f);
}

int main(void)
{
  static uint32_t in[2 * ITEMS], out[ITEMS], xs[NX], ss[NS];
  static char src[64 * 1024];
  char name[256] = "", pver[256] = "", dver[256] = "", pname[256] = "";
  const char *expect = getenv("ROTCHECK_EXPECT");
  const char *only = getenv("ROTCHECK_ONLY");
  int i, n, len = 0, total_bad = 0, kernels = 0, failed_kernels = 0;
  cl_platform_id plat; cl_device_id dev; cl_int err;

  control = getenv("ROTCHECK_CONTROL") != NULL;
  setvbuf(stdout, NULL, _IOLBF, 0);

  /* inputs */
  n = 0;
  xs[n++] = 0; xs[n++] = 1; xs[n++] = 0x80000000u; xs[n++] = 0xFFFFFFFFu;
  xs[n++] = 0x12345678u; xs[n++] = 0xDEADBEEFu; xs[n++] = 0x00FF00FFu; xs[n++] = 0xAAAAAAAAu;
  for (i = 0; i < 32; i++) xs[n++] = 1u << i;
  for (i = 0; i < 32; i++) xs[n++] = ~(1u << i);
  while (n < NX) xs[n++] = rnd();
  n = 0;
  for (i = 0; i < 64; i++) ss[n++] = (uint32_t)i;              /* 0..63 */
  for (i = 1; i <= 32; i++) ss[n++] = (uint32_t)-i;            /* -1..-32 */
  ss[n++] = 64; ss[n++] = 65; ss[n++] = 95; ss[n++] = 96; ss[n++] = 127; ss[n++] = 128;
  ss[n++] = 255; ss[n++] = 256; ss[n++] = 0x7FFFFFFFu; ss[n++] = 0x80000000u;
  ss[n++] = 0x80000001u; ss[n++] = 0x8000001Fu; ss[n++] = 0x00010000u; ss[n++] = 0x00010003u;
  while (n < NS) ss[n++] = rnd();
  for (i = 0; i < ITEMS; i++) { in[2 * i] = xs[i / NS]; in[2 * i + 1] = ss[i % NS]; }

  /* kernels */
#define ADD(...) len += snprintf(src + len, sizeof(src) - len, __VA_ARGS__)
  ADD("#define HEAD size_t i = get_global_id(0); uint x = in[2*i]; uint s = in[2*i+1];\n");
  ADD("__kernel void var_l(__global const uint *in, __global uint *out) { HEAD out[i] = rotate(x, s); }\n");
  ADD("__kernel void var_r(__global const uint *in, __global uint *out) { HEAD out[i] = (x >> s) | (x << (32u - s)); }\n");
  ADD("__kernel void var_c(__global const uint *in, __global uint *out) { HEAD out[i] = (x << s) | (x >> (32u - s)); }\n");
  for (i = 1; i < 32 && !(only && !strcmp(only, "var")); i++) {
    ADD("__kernel void cl_%d(__global const uint *in, __global uint *out) { HEAD out[i] = rotate(x, %du) + (s & 0u); }\n", i, i);
    ADD("__kernel void cr_%d(__global const uint *in, __global uint *out) { HEAD out[i] = ((x >> %du) | (x << %du)) + (s & 0u); }\n", i, i, 32 - i);
  }

  CHK(clGetPlatformIDs(1, &plat, NULL));
  CHK(clGetDeviceIDs(plat, CL_DEVICE_TYPE_ALL, 1, &dev, NULL));
  clGetPlatformInfo(plat, CL_PLATFORM_NAME, sizeof(pname), pname, NULL);
  clGetPlatformInfo(plat, CL_PLATFORM_VERSION, sizeof(pver), pver, NULL);
  clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof(name), name, NULL);
  clGetDeviceInfo(dev, CL_DRIVER_VERSION, sizeof(dver), dver, NULL);
  printf("platform: %s (%s)\ndevice: %s\ndriver version: %s\n", pname, pver, name, dver);
  show_library();
  if (control) printf("CONTROL RUN: the reference is wrong on purpose; mismatches are expected\n");
  if (expect && !strstr(name, expect)) {
    printf("WRONG DEVICE: expected a name containing \"%s\"\n", expect);
    return 3;
  }

  cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CHK(err);
  cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CHK(err);
  const char *srcp = src; size_t srclen = (size_t)len;
  cl_program prog = clCreateProgramWithSource(ctx, 1, &srcp, &srclen, &err); CHK(err);
  err = clBuildProgram(prog, 1, &dev, "-cl-std=CL1.1", NULL, NULL);
  if (err != CL_SUCCESS) {
    static char log[32768];
    clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
    printf("OPENCL ERROR %d building the kernels:\n%s\n", (int)err, log);
    return 2;
  }
  if (getenv("ROTCHECK_COMPILE_ONLY")) {
    const char *names[3] = { "var_l", "var_r", "var_c" };
    cl_mem sb = clCreateBuffer(ctx, CL_MEM_READ_WRITE, 256, NULL, &err); CHK(err);
    size_t g = 16;
    for (i = 0; i < 3; i++) {
      cl_kernel kern = clCreateKernel(prog, names[i], &err); CHK(err);
      CHK(clSetKernelArg(kern, 0, sizeof(sb), &sb));
      CHK(clSetKernelArg(kern, 1, sizeof(sb), &sb));
      CHK(clEnqueueNDRangeKernel(q, kern, 1, NULL, &g, NULL, 0, NULL, NULL));
    }
    clFlush(q);
    sleep(5);
    printf("compile-only: kernels were handed to the driver\n");
    _exit(0);
  }
  cl_mem ib = clCreateBuffer(ctx, CL_MEM_READ_ONLY, sizeof(in), NULL, &err); CHK(err);
  cl_mem ob = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(out), NULL, &err); CHK(err);
  CHK(clEnqueueWriteBuffer(q, ib, CL_TRUE, 0, sizeof(in), in, 0, NULL, NULL));

  for (int k = 0; k < 3 + 62; k++) {
    char kn[32];
    int kind, c = 0;                      /* kind: 0 left, 1 right */
    if (k == 0) { strcpy(kn, "var_l"); kind = 0; }
    else if (k == 1) { strcpy(kn, "var_r"); kind = 1; }
    else if (k == 2) { strcpy(kn, "var_c"); kind = 0; }
    else {
      if (only && !strcmp(only, "var")) break;
      c = (k - 3) / 2 + 1; kind = (k - 3) % 2;
      snprintf(kn, sizeof(kn), kind ? "cr_%d" : "cl_%d", c);
    }
    cl_kernel kern = clCreateKernel(prog, kn, &err); CHK(err);
    if (getenv("ROTCHECK_VERBOSE")) printf("running %s\n", kn);
    CHK(clSetKernelArg(kern, 0, sizeof(ib), &ib));
    CHK(clSetKernelArg(kern, 1, sizeof(ob), &ob));
    memset(out, 0x5A, sizeof(out));
    CHK(clEnqueueWriteBuffer(q, ob, CL_TRUE, 0, sizeof(out), out, 0, NULL, NULL));
    size_t g = ITEMS;
    CHK(clEnqueueNDRangeKernel(q, kern, 1, NULL, &g, NULL, 0, NULL, NULL));
    CHK(clEnqueueReadBuffer(q, ob, CL_TRUE, 0, sizeof(out), out, 0, NULL, NULL));

    int bad = 0, bad_low = 0, bad_high = 0;
    for (i = 0; i < ITEMS; i++) {
      uint32_t x = in[2 * i], s = c ? (uint32_t)c : in[2 * i + 1];
      uint32_t want = kind ? rotr(x, s + control) : rotl(x, s + control);
      if (out[i] != want) {
        if (bad < 6)
          printf("  MISMATCH %s: x=%08x s=%08x got=%08x expected=%08x\n", kn, x, s, out[i], want);
        bad++;
        if (s < 32) bad_low++; else bad_high++;
      }
    }
    kernels++;
    if (bad) {
      failed_kernels++;
      printf("%-6s FAILED: %d of %d results wrong (amount 0..31: %d, other amounts: %d)\n",
             kn, bad, ITEMS, bad_low, bad_high);
    } else if (k < 3) {
      printf("%-6s ok: %d results match\n", kn, ITEMS);
    }
    total_bad += bad;
    clReleaseKernel(kern);
  }
  printf("ROTCHECK %s: %d kernels, %d with mismatches, %d wrong results in total\n",
         total_bad ? "FAILED" : "PASSED", kernels, failed_kernels, total_bad);
  return total_bad ? 1 : 0;
}
