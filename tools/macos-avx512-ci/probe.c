/* Test only: how macOS reports and enables AVX-512 state. */
#include <stdio.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/sysctl.h>

static unsigned long long xcr0(void)
{
  unsigned int a, d;
  __asm__ __volatile__ (".byte 0x0f,0x01,0xd0" : "=a"(a), "=d"(d) : "c"(0));
  return ((unsigned long long)d << 32) | a;
}

static void cpuid7(unsigned int *b)
{
  unsigned int a = 7, c = 0, d;
  __asm__ __volatile__ ("cpuid" : "+a"(a), "=b"(*b), "+c"(c), "=d"(d));
}

static void *thr(void *p)
{
  (void)p;
  printf("XCR0 on a thread created afterwards = 0x%llx\n", xcr0());
  return 0;
}

int main(void)
{
  int v = -1;
  size_t l = sizeof(v);
  unsigned int ebx7 = 0;
  int rc = sysctlbyname("hw.optional.avx512f", &v, &l, NULL, 0);
  cpuid7(&ebx7);
  printf("sysctl hw.optional.avx512f: rc=%d value=%d\n", rc, v);
  printf("CPUID.7.EBX = 0x%08x (AVX2=%u AVX512F=%u)\n", ebx7, (ebx7 >> 5) & 1, (ebx7 >> 16) & 1);
  printf("XCR0 before any AVX-512 instruction = 0x%llx\n", xcr0());
  if (rc == 0 && v != 0) {
    pthread_t t;
    /* vpxord zmm0,zmm0,zmm0 */
    __asm__ __volatile__ (".byte 0x62,0xf1,0x7d,0x48,0xef,0xc0" : : : "xmm0");
    printf("XCR0 after one AVX-512 instruction = 0x%llx\n", xcr0());
    pthread_create(&t, NULL, thr, NULL);
    pthread_join(t, NULL);
  } else {
    printf("AVX-512 not reported by the OS: instruction not executed\n");
  }
  return 0;
}
