/*
 * SSE-free implementations of memcpy / memset / memmove for kernel mode
 * under clang-cl + lld-link.  Injected into every wdk_add_driver target.
 *
 * Why we need this even with -mgeneral-regs-only:
 *   -mgeneral-regs-only is a COMPILER flag — it stops clang from emitting
 *   xmm/ymm/zmm in its own output.  But the *linker* still has to resolve
 *   `call memcpy/memset/memmove`.  Confirmed via /MAP under lld-link
 *   (clang 19 + WDK 10.0.19041): both functions resolve to
 *   `ntoskrnl.lib:memcpy.obj`, which Microsoft ships as an SSE-using
 *   static implementation (uses _mm_stream_ps, _mm_prefetch, _mm_sfence,
 *   __m128 stores) inside the otherwise import-only ntoskrnl.lib.
 *   lld-link prefers that static implementation over the import stub.
 *
 *   That implementation is "safe enough" in normal driver context
 *   (Microsoft saves user FPU on KM entry), but at IRQL >= DISPATCH_LEVEL
 *   or inside DPC/ISR callbacks where xmm state is not guaranteed to be
 *   saved, an unsupervised SSE memcpy can clobber user FP state on
 *   context switch -> bugcheck 7E (SYSTEM_THREAD_EXCEPTION_NOT_HANDLED).
 *   Providing our own non-SSE implementation defeats the static one
 *   in ntoskrnl.lib (selectany: linker picks ours first) and removes
 *   the failure mode entirely.
 *
 *   Touching xmm in KM without Ke{Save,Restore}FloatingPointState
 *   clobbers user FP state on context switch -> bugcheck 7E
 *   (SYSTEM_THREAD_EXCEPTION_NOT_HANDLED).
 *
 * Why volatile inline asm, not __stosb / __movsb intrinsics:
 *   clang's LoopIdiomRecognize pass runs after intrinsic lowering and is
 *   willing to rewrite a byte-write loop (even one originating from
 *   __stosb) into `call memset` -> infinite recursion -> bugcheck 7F
 *   arg=8 (#DF, stack overflow).  Both -fno-builtin-memset and
 *   __attribute__((no_builtin("memset"))) were verified NOT to block this
 *   rewrite.  Volatile inline asm is opaque to LoopIdiomRecognize, so the
 *   compiler can't recognise the body as a memset/memcpy pattern at all.
 */

/* Only need size_t — <stddef.h> is freestanding so it works without
 * _AMD64_/_ARM64_ predefined, which keeps clangd LSP happy. */
#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n) {
    void *d = dst;
    const void *s = src;
    size_t c = n;
    __asm__ __volatile__("rep movsb"
        : "+D"(d), "+S"(s), "+c"(c)
        :
        : "memory");
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    void *d = dst;
    size_t cnt = n;
    __asm__ __volatile__("rep stosb"
        : "+D"(d), "+c"(cnt)
        : "a"((unsigned char)c)
        : "memory");
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    /* Forward path is safe when dst is not strictly inside [src, src+n). */
    if ((unsigned char *)dst <= (const unsigned char *)src ||
        (unsigned char *)dst >= (const unsigned char *)src + n) {
        void *d = dst;
        const void *s = src;
        size_t c = n;
        __asm__ __volatile__("rep movsb"
            : "+D"(d), "+S"(s), "+c"(c)
            :
            : "memory");
    } else {
        /* Backward path: set DF, copy from end, clear DF. */
        unsigned char *d = (unsigned char *)dst + n - 1;
        const unsigned char *s = (const unsigned char *)src + n - 1;
        size_t c = n;
        __asm__ __volatile__(
            "std\n\t"
            "rep movsb\n\t"
            "cld"
            : "+D"(d), "+S"(s), "+c"(c)
            :
            : "memory", "cc");
    }
    return dst;
}
