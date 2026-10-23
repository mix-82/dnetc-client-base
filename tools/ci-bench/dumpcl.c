/*
 * dumpcl.c: build an OpenCL kernel source file and write the driver's
 * compiled form (clGetProgramInfo CL_PROGRAM_BINARIES) to a file, so the
 * intermediate representation can be inspected for rotate intrinsics.
 *
 * usage: dumpcl kernel.cl out.bin [gpu|all]
 *   gpu  (default) only CL_DEVICE_TYPE_GPU devices
 *   all  any device type, for machines without a usable GPU
 *
 * Used by .github/workflows/ci-platforms.yml on macOS (Apple Silicon).
 */
#ifdef __APPLE__
#include <OpenCL/opencl.h>
#else
#include <CL/cl.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *slurp(const char *path, size_t *len)
{
  FILE *f = fopen(path, "rb");
  char *buf;

  if (!f)
  {
    perror(path);
    exit(1);
  }
  fseek(f, 0, SEEK_END);
  *len = (size_t)ftell(f);
  rewind(f);
  buf = malloc(*len + 1);
  if (fread(buf, 1, *len, f) != *len)
  {
    perror(path);
    exit(1);
  }
  buf[*len] = 0;
  fclose(f);
  return buf;
}

int main(int argc, char **argv)
{
  size_t len;
  char *src;
  cl_platform_id plat;
  cl_device_id dev;
  cl_device_type want = CL_DEVICE_TYPE_GPU;
  cl_device_type type;
  cl_context ctx;
  cl_program prog;
  cl_int err;
  char name[256];
  char vendor[256];
  char version[256];
  size_t logn;
  char *log;
  size_t binlen;
  unsigned char *bin;
  unsigned char *bins[1];
  FILE *out;

  if (argc < 3)
  {
    fprintf(stderr, "usage: %s kernel.cl out.bin [gpu|all]\n", argv[0]);
    return 1;
  }
  if (argc > 3 && strcmp(argv[3], "all") == 0)
    want = CL_DEVICE_TYPE_ALL;

  src = slurp(argv[1], &len);

  if (clGetPlatformIDs(1, &plat, NULL) != CL_SUCCESS)
  {
    fprintf(stderr, "no OpenCL platform\n");
    return 2;
  }
  if (clGetDeviceIDs(plat, want, 1, &dev, NULL) != CL_SUCCESS)
  {
    fprintf(stderr, "no OpenCL device of the requested type\n");
    return 2;
  }
  clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
  clGetDeviceInfo(dev, CL_DEVICE_VENDOR, sizeof vendor, vendor, NULL);
  clGetDeviceInfo(dev, CL_DEVICE_VERSION, sizeof version, version, NULL);
  clGetDeviceInfo(dev, CL_DEVICE_TYPE, sizeof type, &type, NULL);
  printf("device: %s (%s), %s, type %s\n", name, vendor, version,
         (type & CL_DEVICE_TYPE_GPU) ? "GPU" : (type & CL_DEVICE_TYPE_CPU) ? "CPU" : "other");

  ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
  if (err != CL_SUCCESS)
  {
    fprintf(stderr, "clCreateContext failed: %d\n", err);
    return 3;
  }
  prog = clCreateProgramWithSource(ctx, 1, (const char **)&src, &len, &err);
  if (err != CL_SUCCESS)
  {
    fprintf(stderr, "clCreateProgramWithSource failed: %d\n", err);
    return 3;
  }
  err = clBuildProgram(prog, 1, &dev, "-cl-std=CL1.1", NULL, NULL);

  clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &logn);
  log = malloc(logn + 1);
  clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, logn, log, NULL);
  log[logn] = 0;
  if (logn > 1)
    fprintf(stderr, "build log:\n%s\n", log);
  if (err != CL_SUCCESS)
  {
    fprintf(stderr, "clBuildProgram failed: %d\n", err);
    return 4;
  }

  clGetProgramInfo(prog, CL_PROGRAM_BINARY_SIZES, sizeof binlen, &binlen, NULL);
  bin = malloc(binlen);
  bins[0] = bin;
  clGetProgramInfo(prog, CL_PROGRAM_BINARIES, sizeof bins, bins, NULL);

  out = fopen(argv[2], "wb");
  if (!out)
  {
    perror(argv[2]);
    return 5;
  }
  fwrite(bin, 1, binlen, out);
  fclose(out);
  printf("wrote %lu bytes to %s\n", (unsigned long)binlen, argv[2]);
  return 0;
}
