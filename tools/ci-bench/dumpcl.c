/*
 * dumpcl.c: build an OpenCL kernel source file and write the driver's
 * compiled form (clGetProgramInfo CL_PROGRAM_BINARIES) to a file, so the
 * intermediate representation can be inspected for rotate intrinsics.
 *
 * usage: dumpcl kernel.cl out.bin [gpu|all|VENDOR]
 *   gpu     (default) the first CL_DEVICE_TYPE_GPU device
 *   all     any device type, for machines without a usable GPU
 *   VENDOR  the first GPU whose CL_DEVICE_VENDOR contains this text
 *           (e.g. AMD on a Mac with both an Intel and an AMD GPU)
 *
 * On Intel Macs the driver returns a property list naming the code object
 * in its compiler service cache (/private/var/db/CVMS/). That file is
 * unlinked as soon as it is handed over and lives on only as a mapping in
 * this process, so the mapped regions carrying its name are written to
 * out.bin.cvms (the file itself, if it still exists, is copied instead).
 *
 * Used by .github/workflows/ci-platforms.yml on macOS.
 */
#ifdef __APPLE__
#include <OpenCL/opencl.h>
#else
#include <CL/cl.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <libproc.h>
#include <unistd.h>
#endif

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
  cl_uint nkern;
  const char *cache;
  size_t i;

  if (argc < 3)
  {
    fprintf(stderr, "usage: %s kernel.cl out.bin [gpu|all]\n", argv[0]);
    return 1;
  }
  const char *wantVendor = NULL;
  if (argc > 3 && strcmp(argv[3], "all") == 0)
    want = CL_DEVICE_TYPE_ALL;
  else if (argc > 3 && strcmp(argv[3], "gpu") != 0)
    wantVendor = argv[3];

  src = slurp(argv[1], &len);

  if (clGetPlatformIDs(1, &plat, NULL) != CL_SUCCESS)
  {
    fprintf(stderr, "no OpenCL platform\n");
    return 2;
  }
  if (wantVendor != NULL)
  {
    cl_device_id devs[16];
    cl_uint ndev = 0;
    cl_uint i;
    if (clGetDeviceIDs(plat, want, 16, devs, &ndev) != CL_SUCCESS || ndev == 0)
    {
      fprintf(stderr, "no OpenCL GPU device\n");
      return 2;
    }
    dev = NULL;
    for (i = 0; i < ndev; i++)
    {
      clGetDeviceInfo(devs[i], CL_DEVICE_VENDOR, sizeof vendor, vendor, NULL);
      if (strstr(vendor, wantVendor) != NULL)
      {
        dev = devs[i];
        break;
      }
    }
    if (dev == NULL)
    {
      fprintf(stderr, "no OpenCL GPU device with vendor %s\n", wantVendor);
      return 2;
    }
  }
  else if (clGetDeviceIDs(plat, want, 1, &dev, NULL) != CL_SUCCESS)
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

  /* make sure the device code exists before asking for the binary */
  if (clCreateKernelsInProgram(prog, 0, NULL, &nkern) == CL_SUCCESS)
    printf("kernels in program: %u\n", (unsigned)nkern);

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

  /* a path into the compiler service cache: copy that file now */
  cache = NULL;
  for (i = 0; i + 16 < binlen; i++)
  {
    if (memcmp(bin + i, "/private/var/db/", 16) == 0)
    {
      cache = (const char *)bin + i;
      break;
    }
  }
  if (cache != NULL)
  {
    char cvmsname[1024];
    FILE *in;
    size_t n;
    unsigned long total = 0;
    char buf[65536];

    snprintf(cvmsname, sizeof cvmsname, "%s.cvms", argv[2]);
    in = fopen(cache, "rb");
    if (!in)
    {
      perror(cache);
#ifdef __APPLE__
      /* already unlinked: find the mapping by its file name and dump it */
      {
        mach_vm_address_t addr = 0;
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count;
        mach_port_t obj;
        char path[1024];
        const char *base = strrchr(cache, '/');
        unsigned regions = 0;

        if (base != NULL)
          base++;
        else
          base = cache;
        out = fopen(cvmsname, "wb");
        if (!out)
        {
          perror(cvmsname);
          return 0;
        }
        for (;;)
        {
          count = VM_REGION_BASIC_INFO_COUNT_64;
          if (mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                             (vm_region_info_t)&info, &count, &obj) != KERN_SUCCESS)
            break;
          if ((info.protection & VM_PROT_READ) != 0
              && proc_regionfilename(getpid(), addr, path, sizeof path) > 0
              && strstr(path, base) != NULL)
          {
            fwrite((const void *)(uintptr_t)addr, 1, (size_t)size, out);
            total += (unsigned long)size;
            regions++;
            printf("mapped region %#llx + %llu, %s\n", (unsigned long long)addr,
                   (unsigned long long)size, path);
          }
          addr += size;
        }
        fclose(out);
        if (regions == 0)
        {
          printf("no mapping of %s found in this process\n", base);
          remove(cvmsname);
          return 0;
        }
        printf("wrote %u mapped regions (%lu bytes) of %s to %s\n", regions, total, base, cvmsname);
      }
#endif
      return 0;
    }
    out = fopen(cvmsname, "wb");
    if (!out)
    {
      perror(cvmsname);
      return 0;
    }
    while ((n = fread(buf, 1, sizeof buf, in)) > 0)
    {
      fwrite(buf, 1, n, out);
      total += n;
    }
    fclose(in);
    fclose(out);
    printf("copied code object %s (%lu bytes) to %s\n", cache, total, cvmsname);
  }
  return 0;
}
