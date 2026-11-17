/* Stack-growth test for the MIX NEON and MIX NEON HYBRID cores on Windows.
 *
 * Windows commits stack pages on demand through a guard page, so a function
 * must not touch memory more than one page below the committed stack.
 * The two cores use frames of about 4 KB. This calls each core on fresh
 * threads (4 KB of stack committed) with the stack pointer at every 16-byte
 * position of two pages, so the core's frame crosses the guard page in
 * every possible way. A core that skipped the guard page would crash with
 * an access violation.
 *
 * "stackprobe info" prints how a fresh thread's stack is laid out
 * (committed, guard and reserved regions).
 * "stackprobe bad N" is the control: a function that moves sp down N pages
 * and writes there without touching the pages in between. Run for growing
 * N, it shows how far below sp a write is tolerated on this system; the
 * first N that crashes is the limit a core must stay under.
 */
#include <windows.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned int u32;
typedef struct {
  struct { u32 hi, lo; } plain;
  struct { u32 hi, lo; } cypher;
  struct { u32 hi, mid, lo; } L0;
  struct { u32 count, hi, mid, lo; } check;
} RC5_72UnitWork;

extern int rc5_72_unit_func_neon_mix(RC5_72UnitWork *, u32 *, void *);
extern int rc5_72_unit_func_neon_hyb(RC5_72UnitWork *, u32 *, void *);
extern int bad_probe(size_t pages, void *);

struct job { int core; size_t k; int result; u32 iters; size_t pages; };

static MEMORY_BASIC_INFORMATION g_m[4];
static char *g_sp;

static DWORD WINAPI thr(LPVOID arg)
{
  struct job *j = (struct job *)arg;
  volatile char *p = (volatile char *)_alloca(j->k + 16);
  RC5_72UnitWork w;
  u32 it;
  p[0] = 1;                       /* commit down to here; guard page is next */
  memset(&w, 0, sizeof w);
  w.cypher.lo = 0x12345678; w.cypher.hi = 0x9abcdef0;
  if (j->core == 2) { j->result = bad_probe(j->pages, &w); return 0; }
  if (j->core == 3) {             /* info: regions at and below sp */
    char *a = (char *)&w;
    int i;
    g_sp = a;
    for (i = 0; i < 4; i++) {
      if (!VirtualQuery(a, &g_m[i], sizeof g_m[i])) break;
      a = (char *)g_m[i].BaseAddress - 1;
    }
    return 0;
  }
  it = (j->core == 0) ? 32 : 16;
  j->result = (j->core == 0) ? rc5_72_unit_func_neon_mix(&w, &it, 0)
                             : rc5_72_unit_func_neon_hyb(&w, &it, 0);
  j->iters = it;
  return 0;
}

static int run(struct job *j)
{
  HANDLE h = CreateThread(NULL, 4096, thr, j, 0, NULL);
  if (!h) { printf("CreateThread failed\n"); return -1; }
  WaitForSingleObject(h, INFINITE);
  CloseHandle(h);
  return 0;
}

int main(int argc, char **argv)
{
  struct job j;
  int core, bad = 0;
  long n = 0;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc > 1 && strcmp(argv[1], "info") == 0) {
    int i;
    j.core = 3; j.k = 0;
    run(&j);
    printf("fresh thread (CreateThread, 4096 bytes commit requested): address in frame %p\n", g_sp);
    for (i = 0; i < 4; i++)
      printf("  region %d: %p .. %p  %7llu bytes  %s%s\n", i, g_m[i].BaseAddress,
             (char *)g_m[i].BaseAddress + g_m[i].RegionSize, (unsigned long long)g_m[i].RegionSize,
             g_m[i].State == MEM_COMMIT ? "committed" : g_m[i].State == MEM_RESERVE ? "reserved" : "free",
             (g_m[i].Protect & PAGE_GUARD) ? " GUARD" : "");
    printf("  bytes committed below the frame address: %llu\n",
           (unsigned long long)(g_sp - (char *)g_m[0].BaseAddress));
    return 0;
  }
  if (argc > 2 && strcmp(argv[1], "bad") == 0) {
    j.core = 2; j.k = 0; j.result = 0; j.pages = (size_t)atoi(argv[2]);
    run(&j);
    printf("control: write %u pages below sp did not crash\n", (unsigned)j.pages);
    return 0;
  }
  for (core = 0; core < 2; core++)
    for (j.k = 0; j.k < 8192; j.k += 16) {
      j.core = core; j.result = -1; j.iters = 0;
      if (run(&j)) return 2;
      n++;
      if (j.result != 1 || j.iters != (u32)(core == 0 ? 32 : 16)) {
        if (bad++ < 5) printf("core %d k=%u: result %d iterations %u\n", core, (unsigned)j.k, j.result, j.iters);
      }
    }
  printf("stackprobe: %ld calls (2 cores x 512 stack positions), %d unexpected results, no crash\n", n, bad);
  return bad != 0;
}
