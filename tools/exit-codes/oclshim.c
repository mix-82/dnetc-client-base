/* oclshim.c - LD_PRELOAD interposer for the OpenCL calls the dnetc client makes.
 *
 * Audit tool only, not part of the client. It does two things:
 *
 *  1. Counts every object the client creates and releases (contexts, queues,
 *     buffers, programs, kernels, events) and prints the totals when the
 *     process exits, so a per-launch leak shows up as created != released.
 *
 *  2. Injects a failure into one call, to exercise error paths that a healthy
 *     driver never takes:
 *       OCLSHIM_FAIL=<function>:<n>[:<code>]
 *     makes the n-th call (1-based, 0 = every call) of <function> fail with
 *     <code> (default -5, CL_OUT_OF_RESOURCES).
 *     OCLSHIM_BUILDLOG_SIZE0=1 makes the CL_PROGRAM_BUILD_LOG size query
 *     report 0 bytes.
 *
 *  OCLSHIM_ALLTYPES=1 turns CL_DEVICE_TYPE_GPU requests into
 *  CL_DEVICE_TYPE_ALL so that a CPU device (PoCL) is offered to the client.
 *
 * Build: gcc -shared -fPIC -O1 -o oclshim.so oclshim.c -ldl
 * Use:   LD_PRELOAD=./oclshim.so ./dnetc -test rc5-72
 */
#define _GNU_SOURCE
#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { O_CTX, O_QUEUE, O_MEM, O_PROG, O_KERN, O_EVT, O_N };
static const char *oname[O_N] = { "context", "queue", "mem", "program", "kernel", "event" };
static long created[O_N], released[O_N], releasefail[O_N];
static long ncalls_launch, ncalls_wait, ncalls_map, ncalls_unmap, ncalls_build;
static long injected;

/* per-device kernel launch counters: the client's start-up sanity check is the
   only caller that launches kernels without asking for an event */
#define MAXQ 64
static struct { cl_command_queue q; cl_device_id d; } qmap[MAXQ];
static int nq;
#define MAXD 8
static struct { cl_device_id d; long noevt, withevt; } dstat[MAXD];
static int nd;

static void count_launch(cl_command_queue q, int has_event)
{
  int i, j;
  for (i = nq - 1; i >= 0; i--)
    if (qmap[i].q == q)
      break;
  if (i < 0)
    return;
  for (j = 0; j < nd; j++)
    if (dstat[j].d == qmap[i].d)
      break;
  if (j == nd)
  {
    if (nd == MAXD)
      return;
    dstat[nd++].d = qmap[i].d;
  }
  if (has_event) dstat[j].withevt++; else dstat[j].noevt++;
}

static const char *fail_name;
static long fail_n = -1;
static int fail_code = -5;
static long fail_seen;
static int inited;

static void report(void)
{
  int i;
  char buf[1024];
  int n = 0;
  n += snprintf(buf + n, sizeof(buf) - n, "[oclshim pid %d] object            created  released  release-errors  outstanding\n", (int)getpid());
  for (i = 0; i < O_N; i++)
    n += snprintf(buf + n, sizeof(buf) - n, "[oclshim]   %-12s %12ld %9ld %15ld %12ld\n", oname[i], created[i], released[i], releasefail[i], created[i] - released[i]);
  n += snprintf(buf + n, sizeof(buf) - n, "[oclshim]   calls: clBuildProgram=%ld clEnqueueNDRangeKernel=%ld clWaitForEvents=%ld clEnqueueMapBuffer=%ld clEnqueueUnmapMemObject=%ld; failures injected=%ld\n",
                ncalls_build, ncalls_launch, ncalls_wait, ncalls_map, ncalls_unmap, injected);
  fputs(buf, stderr);
  for (i = 0; i < nd; i++)
  {
    char name[128] = "?";
    clGetDeviceInfo(dstat[i].d, CL_DEVICE_NAME, sizeof(name), name, NULL);
    fprintf(stderr, "[oclshim]   device \"%s\": kernel launches without event=%ld, with event=%ld\n", name, dstat[i].noevt, dstat[i].withevt);
  }
}

static void init(void)
{
  const char *e;
  if (inited)
    return;
  inited = 1;
  e = getenv("OCLSHIM_FAIL");
  if (e && *e)
  {
    static char name[64];
    const char *c = strchr(e, ':');
    size_t len = c ? (size_t)(c - e) : strlen(e);
    if (len >= sizeof(name))
      len = sizeof(name) - 1;
    memcpy(name, e, len);
    name[len] = 0;
    fail_name = name;
    fail_n = 1;
    if (c)
    {
      fail_n = strtol(c + 1, NULL, 10);
      c = strchr(c + 1, ':');
      if (c)
        fail_code = (int)strtol(c + 1, NULL, 10);
    }
    fprintf(stderr, "[oclshim] will fail call %ld of %s with code %d\n", fail_n, fail_name, fail_code);
  }
  atexit(report);
}

/* returns nonzero if this call of 'name' must fail */
static int should_fail(const char *name)
{
  init();
  if (!fail_name || strcmp(fail_name, name) != 0)
    return 0;
  fail_seen++;
  if (fail_n == 0 || fail_seen == fail_n)
  {
    injected++;
    fprintf(stderr, "[oclshim] injecting failure %d into %s (call %ld)\n", fail_code, name, fail_seen);
    return 1;
  }
  return 0;
}

#define REAL(ret, name, proto) \
  static ret (*real_##name) proto; \
  if (!real_##name) real_##name = (ret (*) proto) dlsym(RTLD_NEXT, #name)

cl_int clGetDeviceIDs(cl_platform_id p, cl_device_type t, cl_uint n, cl_device_id *d, cl_uint *nr)
{
  REAL(cl_int, clGetDeviceIDs, (cl_platform_id, cl_device_type, cl_uint, cl_device_id *, cl_uint *));
  if (should_fail("clGetDeviceIDs"))
    return fail_code;
  if (t == CL_DEVICE_TYPE_GPU && getenv("OCLSHIM_ALLTYPES"))
    t = CL_DEVICE_TYPE_ALL;
  return real_clGetDeviceIDs(p, t, n, d, nr);
}

cl_context clCreateContext(const cl_context_properties *pr, cl_uint n, const cl_device_id *d,
                           void (CL_CALLBACK *cb)(const char *, const void *, size_t, void *), void *ud, cl_int *err)
{
  cl_context c;
  cl_int e = CL_SUCCESS;
  REAL(cl_context, clCreateContext, (const cl_context_properties *, cl_uint, const cl_device_id *,
                                     void (CL_CALLBACK *)(const char *, const void *, size_t, void *), void *, cl_int *));
  if (should_fail("clCreateContext"))
  {
    if (err) *err = fail_code;
    return NULL;
  }
  c = real_clCreateContext(pr, n, d, cb, ud, &e);
  if (err) *err = e;
  if (e == CL_SUCCESS) created[O_CTX]++;
  return c;
}

cl_int clReleaseContext(cl_context c)
{
  cl_int e;
  REAL(cl_int, clReleaseContext, (cl_context));
  init();
  e = real_clReleaseContext(c);
  if (e == CL_SUCCESS) released[O_CTX]++; else releasefail[O_CTX]++;
  return e;
}

cl_command_queue clCreateCommandQueue(cl_context c, cl_device_id d, cl_command_queue_properties p, cl_int *err)
{
  cl_command_queue q;
  cl_int e = CL_SUCCESS;
  REAL(cl_command_queue, clCreateCommandQueue, (cl_context, cl_device_id, cl_command_queue_properties, cl_int *));
  if (should_fail("clCreateCommandQueue"))
  {
    if (err) *err = fail_code;
    return NULL;
  }
  q = real_clCreateCommandQueue(c, d, p, &e);
  if (err) *err = e;
  if (e == CL_SUCCESS) created[O_QUEUE]++;
  if (e == CL_SUCCESS && nq < MAXQ)
  {
    qmap[nq].q = q;
    qmap[nq].d = d;
    nq++;
  }
  return q;
}

cl_int clReleaseCommandQueue(cl_command_queue q)
{
  cl_int e;
  REAL(cl_int, clReleaseCommandQueue, (cl_command_queue));
  init();
  e = real_clReleaseCommandQueue(q);
  if (e == CL_SUCCESS) released[O_QUEUE]++; else releasefail[O_QUEUE]++;
  return e;
}

cl_mem clCreateBuffer(cl_context c, cl_mem_flags f, size_t sz, void *hp, cl_int *err)
{
  cl_mem m;
  cl_int e = CL_SUCCESS;
  REAL(cl_mem, clCreateBuffer, (cl_context, cl_mem_flags, size_t, void *, cl_int *));
  if (should_fail("clCreateBuffer"))
  {
    if (err) *err = fail_code;
    return NULL;
  }
  m = real_clCreateBuffer(c, f, sz, hp, &e);
  if (err) *err = e;
  if (e == CL_SUCCESS) created[O_MEM]++;
  return m;
}

cl_int clReleaseMemObject(cl_mem m)
{
  cl_int e;
  REAL(cl_int, clReleaseMemObject, (cl_mem));
  init();
  e = real_clReleaseMemObject(m);
  if (e == CL_SUCCESS) released[O_MEM]++; else releasefail[O_MEM]++;
  return e;
}

cl_program clCreateProgramWithSource(cl_context c, cl_uint n, const char **s, const size_t *l, cl_int *err)
{
  cl_program p;
  cl_int e = CL_SUCCESS;
  REAL(cl_program, clCreateProgramWithSource, (cl_context, cl_uint, const char **, const size_t *, cl_int *));
  if (should_fail("clCreateProgramWithSource"))
  {
    if (err) *err = fail_code;
    return NULL;
  }
  p = real_clCreateProgramWithSource(c, n, s, l, &e);
  if (err) *err = e;
  if (e == CL_SUCCESS) created[O_PROG]++;
  return p;
}

cl_int clReleaseProgram(cl_program p)
{
  cl_int e;
  REAL(cl_int, clReleaseProgram, (cl_program));
  init();
  e = real_clReleaseProgram(p);
  if (e == CL_SUCCESS) released[O_PROG]++; else releasefail[O_PROG]++;
  return e;
}

cl_int clBuildProgram(cl_program p, cl_uint n, const cl_device_id *d, const char *opt,
                      void (CL_CALLBACK *cb)(cl_program, void *), void *ud)
{
  REAL(cl_int, clBuildProgram, (cl_program, cl_uint, const cl_device_id *, const char *,
                                void (CL_CALLBACK *)(cl_program, void *), void *));
  ncalls_build++;
  if (should_fail("clBuildProgram"))
    return fail_code;
  return real_clBuildProgram(p, n, d, opt, cb, ud);
}

cl_int clGetProgramBuildInfo(cl_program p, cl_device_id d, cl_program_build_info i, size_t sz, void *v, size_t *szr)
{
  REAL(cl_int, clGetProgramBuildInfo, (cl_program, cl_device_id, cl_program_build_info, size_t, void *, size_t *));
  if (should_fail("clGetProgramBuildInfo"))
    return fail_code;
  if (i == CL_PROGRAM_BUILD_LOG && getenv("OCLSHIM_BUILDLOG_SIZE0"))
  {
    if (szr) *szr = 0;
    return CL_SUCCESS;
  }
  return real_clGetProgramBuildInfo(p, d, i, sz, v, szr);
}

cl_kernel clCreateKernel(cl_program p, const char *name, cl_int *err)
{
  cl_kernel k;
  cl_int e = CL_SUCCESS;
  REAL(cl_kernel, clCreateKernel, (cl_program, const char *, cl_int *));
  if (should_fail("clCreateKernel"))
  {
    if (err) *err = fail_code;
    return NULL;
  }
  k = real_clCreateKernel(p, name, &e);
  if (err) *err = e;
  if (e == CL_SUCCESS) created[O_KERN]++;
  return k;
}

cl_int clReleaseKernel(cl_kernel k)
{
  cl_int e;
  REAL(cl_int, clReleaseKernel, (cl_kernel));
  init();
  e = real_clReleaseKernel(k);
  if (e == CL_SUCCESS) released[O_KERN]++; else releasefail[O_KERN]++;
  return e;
}

cl_int clEnqueueNDRangeKernel(cl_command_queue q, cl_kernel k, cl_uint dim, const size_t *off, const size_t *gws,
                              const size_t *lws, cl_uint nw, const cl_event *wl, cl_event *evt)
{
  cl_int e;
  REAL(cl_int, clEnqueueNDRangeKernel, (cl_command_queue, cl_kernel, cl_uint, const size_t *, const size_t *,
                                        const size_t *, cl_uint, const cl_event *, cl_event *));
  ncalls_launch++;
  if (should_fail("clEnqueueNDRangeKernel"))
    return fail_code;
  e = real_clEnqueueNDRangeKernel(q, k, dim, off, gws, lws, nw, wl, evt);
  if (e == CL_SUCCESS && evt) created[O_EVT]++;
  if (e == CL_SUCCESS) count_launch(q, evt != NULL);
  return e;
}

cl_int clWaitForEvents(cl_uint n, const cl_event *l)
{
  cl_int e;
  REAL(cl_int, clWaitForEvents, (cl_uint, const cl_event *));
  ncalls_wait++;
  /* the real wait is done first so that the kernel has really finished */
  e = real_clWaitForEvents(n, l);
  if (should_fail("clWaitForEvents"))
    return fail_code;
  return e;
}

cl_int clReleaseEvent(cl_event ev)
{
  cl_int e;
  REAL(cl_int, clReleaseEvent, (cl_event));
  init();
  e = real_clReleaseEvent(ev);
  if (e == CL_SUCCESS) released[O_EVT]++; else releasefail[O_EVT]++;
  return e;
}

void *clEnqueueMapBuffer(cl_command_queue q, cl_mem m, cl_bool blk, cl_map_flags f, size_t off, size_t sz,
                         cl_uint nw, const cl_event *wl, cl_event *evt, cl_int *err)
{
  void *p;
  cl_int e = CL_SUCCESS;
  REAL(void *, clEnqueueMapBuffer, (cl_command_queue, cl_mem, cl_bool, cl_map_flags, size_t, size_t,
                                    cl_uint, const cl_event *, cl_event *, cl_int *));
  ncalls_map++;
  if (should_fail("clEnqueueMapBuffer"))
  {
    if (err) *err = fail_code;
    return NULL;
  }
  p = real_clEnqueueMapBuffer(q, m, blk, f, off, sz, nw, wl, evt, &e);
  if (err) *err = e;
  if (e == CL_SUCCESS && evt) created[O_EVT]++;
  return p;
}

cl_int clEnqueueUnmapMemObject(cl_command_queue q, cl_mem m, void *ptr, cl_uint nw, const cl_event *wl, cl_event *evt)
{
  cl_int e;
  REAL(cl_int, clEnqueueUnmapMemObject, (cl_command_queue, cl_mem, void *, cl_uint, const cl_event *, cl_event *));
  ncalls_unmap++;
  e = real_clEnqueueUnmapMemObject(q, m, ptr, nw, wl, evt);
  if (should_fail("clEnqueueUnmapMemObject"))
    return fail_code;
  if (e == CL_SUCCESS && evt) created[O_EVT]++;
  return e;
}

cl_int clGetEventProfilingInfo(cl_event ev, cl_profiling_info i, size_t sz, void *v, size_t *szr)
{
  REAL(cl_int, clGetEventProfilingInfo, (cl_event, cl_profiling_info, size_t, void *, size_t *));
  if (should_fail("clGetEventProfilingInfo"))
    return fail_code;
  return real_clGetEventProfilingInfo(ev, i, sz, v, szr);
}

cl_int clSetKernelArg(cl_kernel k, cl_uint idx, size_t sz, const void *v)
{
  REAL(cl_int, clSetKernelArg, (cl_kernel, cl_uint, size_t, const void *));
  if (should_fail("clSetKernelArg"))
    return fail_code;
  return real_clSetKernelArg(k, idx, sz, v);
}

cl_int clFlush(cl_command_queue q)
{
  REAL(cl_int, clFlush, (cl_command_queue));
  if (should_fail("clFlush"))
    return fail_code;
  return real_clFlush(q);
}
