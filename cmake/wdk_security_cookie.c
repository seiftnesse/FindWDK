/*
 * Writable shadow of __security_cookie / __security_cookie_complement,
 * injected into every wdk_add_driver target under clang-cl.
 *
 * lld-link places bufferoverflowfastfailk.lib's copy of the cookie in
 * .rdata; the kernel image loader can't randomise a read-only cookie, so
 * it stays at the magic default 0x2B992DDFA232 and __security_init_cookie()
 * fastfails before DriverEntry runs.  __declspec(selectany) gives the
 * linker our writable .data definition to pick over the lib's, so the
 * loader can patch in a per-image random value at load time.
 */

#include <stddef.h>

typedef unsigned __int64 ULONG_PTR;

__declspec(selectany) ULONG_PTR __security_cookie =
    0x00002B992DDFA232;
__declspec(selectany) ULONG_PTR __security_cookie_complement =
    ~0x00002B992DDFA232ULL;
