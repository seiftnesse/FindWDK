/*
 * Force-included shim that papers over two gaps in clang's MSVC
 * kernel-intrinsic support:
 *
 *   1. clang < 20.1.0 declared __readcr4 / __readcr8 / __writecr4 /
 *      __writecr8 with `unsigned long` instead of ULONG64, conflicting
 *      with wdm.h.  Fix landed via
 *      https://github.com/llvm/llvm-project/pull/122238.
 *
 *   2. _disable, _enable, __readcr0, __writecr0 are declared in
 *      <intrin.h> but never inlined to instructions, so the linker hits
 *      undefined symbols on KM code that uses them.
 *
 * Strategy: macro-rename clang's broken/missing-body decls aside, then
 * provide our own static-inline asm bodies on the canonical names.
 *
 * The shim is a no-op under MSVC.
 */

#ifdef __clang__

/* Hide clang's intrin.h decls (wrong types pre-20.1.0 and/or no body) so
 * wdm.h's prototypes are unchallenged; provide inline-asm bodies below. */
#define _disable   __wdk_unused_clang_disable
#define _enable    __wdk_unused_clang_enable
#define __readcr0  __wdk_unused_clang_readcr0
#define __readcr4  __wdk_unused_clang_readcr4
#define __readcr8  __wdk_unused_clang_readcr8
#define __writecr0 __wdk_unused_clang_writecr0
#define __writecr4 __wdk_unused_clang_writecr4
#define __writecr8 __wdk_unused_clang_writecr8
#include <intrin.h>
#undef _disable
#undef _enable
#undef __readcr0
#undef __readcr4
#undef __readcr8
#undef __writecr0
#undef __writecr4
#undef __writecr8

#ifdef __cplusplus
extern "C" {
#endif

#define _WDK_DEF_RDCR(N)                                                 \
    static __forceinline unsigned __int64 __readcr##N(void) {            \
        unsigned __int64 v;                                              \
        __asm__ __volatile__("movq %%cr" #N ", %0" : "=r"(v));           \
        return v;                                                        \
    }
#define _WDK_DEF_WRCR(N)                                                 \
    static __forceinline void __writecr##N(unsigned __int64 v) {         \
        __asm__ __volatile__("movq %0, %%cr" #N ::"r"(v));               \
    }

static __forceinline void _disable(void) {
    __asm__ __volatile__("cli" ::: "memory");
}
static __forceinline void _enable(void) {
    __asm__ __volatile__("sti" ::: "memory");
}

_WDK_DEF_RDCR(0)
_WDK_DEF_RDCR(4)
_WDK_DEF_RDCR(8)
_WDK_DEF_WRCR(0)
_WDK_DEF_WRCR(4)
_WDK_DEF_WRCR(8)

#undef _WDK_DEF_RDCR
#undef _WDK_DEF_WRCR

#ifdef __cplusplus
}
#endif

#endif /* __clang__ */
