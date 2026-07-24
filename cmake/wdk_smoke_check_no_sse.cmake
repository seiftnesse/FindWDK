# wdk_smoke_check_no_sse.cmake
#
# Post-build hard-fail check: scan a .sys file's disassembly for any SSE/AVX
# register reference (xmm/ymm/zmm).  Touching xmm in KM without
# Ke{Save,Restore}FloatingPointState clobbers user FP state on context
# switch -> SYSTEM_THREAD_EXCEPTION_NOT_HANDLED.  clang-cl on x86_64 has
# no fully reliable knob to suppress SSE in compiler-generated code, so
# this is the last-line defence.
#
# A second check scans the mem* wrappers for self-recursion (see
# check_mem_recursion).  It relies on function symbol labels in the
# disassembly; a PE with a stripped COFF symbol table only carries section
# labels (<.text>:), in which case that check is skipped and reported.
#
# Usage:
#   cmake -DSYS_FILE=path/to/driver.sys [-DC_COMPILER=path/to/clang-cl]
#         [-DDISASM_EXE=path/to/llvm-objdump] -P wdk_smoke_check_no_sse.cmake
#
# C_COMPILER is the compiler that built the driver; llvm-objdump is looked
# up next to it.  DISASM_EXE presets the disassembler outright (test hook).

# xmm0..15, ymm0..15, zmm0..15 with a non-identifier char on each side,
# so symbol names merely containing e.g. "xmm0" don't false-match.
set(SSE_RE "[^A-Za-z0-9_][xyz]mm[0-9]+[^A-Za-z0-9_]")
# Whole disasm lines containing at least one such register reference.
set(SSE_LINE_RE "[^\n]*${SSE_RE}[^\n]*")
# llvm-objdump function header, e.g. "0000000140023b30 <memset>:" at
# column 0.  Instruction lines are "<addr>:" so they cannot match this.
set(FUNC_HEADER_RE "\n[0-9a-fA-F]+ <[^>]+>:")

#-----------------------------------------------------------------------
# Checks
#-----------------------------------------------------------------------

# Hard-fail if the disassembly references any SSE/AVX register.
function(check_no_sse SYS_FILE DISASM)
    # Cheap existence test first; the MATCHALL passes below only run on
    # the failure path, to build the report.
    string(REGEX MATCH "${SSE_RE}" SSE_HIT "${DISASM}")
    if (NOT SSE_HIT)
        return()
    endif ()

    # Pad every line end with a space first: a register at end of line
    # would otherwise let SSE_RE's trailing boundary consume the newline,
    # merging two disasm lines into one "line" match.
    string(REPLACE "\n" " \n" DISASM_PADDED "${DISASM}")
    string(REGEX MATCHALL "${SSE_RE}" SSE_HITS "${DISASM_PADDED}")
    string(REGEX MATCHALL "${SSE_LINE_RE}" SSE_LINES "${DISASM_PADDED}")
    list(LENGTH SSE_HITS HIT_COUNT)
    list(LENGTH SSE_LINES LINE_COUNT)

    # Show up to 5 offending lines so the engineer can chase the
    # offending function quickly.
    set(SAMPLE "")
    if (SSE_LINES)
        list(SUBLIST SSE_LINES 0 5 SAMPLE_LINES)
        list(JOIN SAMPLE_LINES "\n    " SAMPLE)
        set(SAMPLE "    ${SAMPLE}\n")
    endif ()
    message(FATAL_ERROR
            "[wdk smoke-check] FAIL: ${HIT_COUNT} SSE/AVX register reference(s) "
            "found in ${SYS_FILE} (${LINE_COUNT} disasm lines).\n"
            "First samples:\n${SAMPLE}"
            "xmm/ymm/zmm in kernel-mode code clobbers user FP state on context "
            "switch -> bugcheck 7E.  Investigate which function emitted them "
            "(IDA: search for 'xmm') and either suppress SSE for it or override "
            "the symbol with a non-SSE implementation.")
endfunction()

# Self-recursion check for mem* wrappers.  clang's LoopIdiomRecognize pass
# can rewrite a byte-loop / __stosb / __movsb body of memset/memcpy/memmove
# back into `call memset` etc., causing infinite recursion -> bugcheck 7F.
# This is independent of -fno-builtin-* and __attribute__((no_builtin)),
# both of which were verified NOT to block it.  Defence is `volatile`
# inline asm in the wrapper body — but if someone reverts to intrinsics,
# this check will catch it before the .sys reaches the system.
#
# Wrappers without a "<FN>:" label in the disassembly (stripped symbol
# table, or dumpbin instead of llvm-objdump) cannot be located; they are
# returned via SKIPPED_OUT so the caller can report them as unchecked.
function(check_mem_recursion SYS_FILE DISASM SKIPPED_OUT)
    set(SKIPPED "")
    foreach (FN memset memcpy memmove)
        string(FIND "${DISASM}" "<${FN}>:" LABEL_POS)
        if (LABEL_POS EQUAL -1)
            list(APPEND SKIPPED ${FN})
            continue()
        endif ()

        # Cut the disasm down to FN's body: from its "<FN>:" label up to
        # the next function header (or EOF if FN is the last function).
        string(SUBSTRING "${DISASM}" ${LABEL_POS} -1 REST)
        string(REGEX MATCH "${FUNC_HEADER_RE}" NEXT_HEADER "${REST}")
        if (NEXT_HEADER)
            string(FIND "${REST}" "${NEXT_HEADER}" BODY_END)
            string(SUBSTRING "${REST}" 0 ${BODY_END} BODY)
        else ()
            set(BODY "${REST}")
        endif ()

        # The label itself accounts for one "<FN>" occurrence; any
        # additional one is a call/jmp target = self-recursion.
        string(REGEX MATCHALL "<${FN}>" SELF_REFS "${BODY}")
        list(LENGTH SELF_REFS REF_COUNT)
        if (REF_COUNT GREATER 1)
            string(LENGTH "${BODY}" BODY_LEN)
            if (BODY_LEN GREATER 800)
                string(SUBSTRING "${BODY}" 0 800 BODY)
                string(APPEND BODY "\n... (truncated)")
            endif ()
            message(FATAL_ERROR
                    "[wdk smoke-check] FAIL: ${FN} contains ${REF_COUNT} self-references "
                    "in ${SYS_FILE} (1 = label, the rest = calls into itself).\n"
                    "Likely LoopIdiomRecognize replaced the body with `call ${FN}` -> "
                    "infinite recursion -> bugcheck 7F (#DF).  The wrapper body MUST "
                    "use volatile inline asm (rep stosb/movsb), NOT __stosb/__movsb "
                    "intrinsics — both -fno-builtin-${FN} and "
                    "__attribute__((no_builtin(\"${FN}\"))) DO NOT block this rewrite.\n"
                    "Body excerpt:\n${BODY}")
        endif ()
    endforeach ()
    set(${SKIPPED_OUT} "${SKIPPED}" PARENT_SCOPE)
endfunction()

#-----------------------------------------------------------------------
# Entry point
#-----------------------------------------------------------------------

if (NOT SYS_FILE)
    message(FATAL_ERROR "wdk_smoke_check_no_sse: SYS_FILE not set")
endif ()

if (NOT EXISTS "${SYS_FILE}")
    message(FATAL_ERROR "wdk_smoke_check_no_sse: file does not exist: ${SYS_FILE}")
endif ()

# Prefer llvm-objdump: it knows Intel syntax and doesn't require a VS
# Developer environment to be initialised (CLion spawns ninja with its own
# PATH, which usually lacks dumpbin).  Look next to the compiler that built
# the driver first — every LLVM flavour (upstream, MS llvm-project,
# VS-bundled clang-cl) ships llvm-objdump in the same bin/ as clang-cl —
# then fall back to a plain PATH search, which also covers dumpbin-only
# MSVC environments.  A preset DISASM_EXE (-D) skips the search entirely.
set(DISASM_HINTS "")
if (C_COMPILER)
    get_filename_component(COMPILER_BIN_DIR "${C_COMPILER}" DIRECTORY)
    list(APPEND DISASM_HINTS "${COMPILER_BIN_DIR}")
endif ()
find_program(DISASM_EXE
        NAMES llvm-objdump dumpbin
        HINTS ${DISASM_HINTS}
)
if (NOT DISASM_EXE)
    message(WARNING "wdk_smoke_check_no_sse: neither llvm-objdump nor dumpbin "
            "found, skipping check")
    return()
endif ()

# Pick command form by tool name.  --no-show-raw-insn drops the raw-byte
# column (~40% of llvm-objdump's output), shrinking both the objdump run
# and the regex scans; nothing in the checks needs the bytes.
get_filename_component(DISASM_NAME "${DISASM_EXE}" NAME_WE)
if (DISASM_NAME STREQUAL "llvm-objdump")
    set(DISASM_ARGS -d --no-show-raw-insn --x86-asm-syntax=intel "${SYS_FILE}")
else ()
    set(DISASM_ARGS /disasm:bytes "${SYS_FILE}")
endif ()

execute_process(
        COMMAND "${DISASM_EXE}" ${DISASM_ARGS}
        OUTPUT_VARIABLE DISASM
        ERROR_VARIABLE DISASM_ERR
        RESULT_VARIABLE DISASM_RC
)
if (NOT DISASM_RC EQUAL 0)
    message(FATAL_ERROR "wdk_smoke_check_no_sse: ${DISASM_NAME} failed "
            "(rc=${DISASM_RC}):\n${DISASM_ERR}")
endif ()

check_no_sse("${SYS_FILE}" "${DISASM}")
check_mem_recursion("${SYS_FILE}" "${DISASM}" SKIPPED_FNS)

if (SKIPPED_FNS)
    list(JOIN SKIPPED_FNS ", " SKIPPED_STR)
    message(STATUS "[wdk smoke-check] OK: no xmm/ymm/zmm in ${SYS_FILE}; "
            "mem* recursion check skipped for ${SKIPPED_STR} "
            "(no function labels in disasm — stripped symbol table?)")
else ()
    message(STATUS "[wdk smoke-check] OK: no xmm/ymm/zmm and no mem* recursion in ${SYS_FILE}")
endif ()
