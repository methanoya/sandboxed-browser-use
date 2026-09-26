/*
 * LD_PRELOAD shim that hides Arm SME from getauxval(AT_HWCAP2).
 *
 * When the CPU reports SME, Chrome 153 on Linux arm64 runs SVE instructions
 * (e.g. CNTD) outside SME streaming mode. On an SME-only CPU such as the Apple
 * M4, which has no SVE, those are undefined: the renderer dies with SIGILL
 * ("Aw, Snap! Error code: 4" on YouTube or Vimeo). The sandbox VM handles SME
 * correctly; this is a Chrome bug. Masking the SME bits makes Chrome take its
 * plain NEON code paths instead.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/auxv.h>

/* HWCAP2 bits 23-30 (SME ... SME_FA64) and 37-42 (SME2 ... SME_F16F16). */
#define SME_HWCAP2_MASK ((0xFFUL << 23) | (0x3FUL << 37))

unsigned long getauxval(unsigned long type) {
  static unsigned long (*real_getauxval)(unsigned long);
  if (!real_getauxval) real_getauxval = dlsym(RTLD_NEXT, "getauxval");
  unsigned long value = real_getauxval(type);
  return type == AT_HWCAP2 ? value & ~SME_HWCAP2_MASK : value;
}
