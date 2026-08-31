/*
 * m1-4-clang-as-semicolon-comment-and-hash-stringify.S — NOT a Mojo
 * compiler defect (unlike the other files in this directory): a build-
 * tooling gotcha in how `cc -c foo.S` (clang, driving its integrated
 * assembler, on this macOS arm64 host) handles two things test authors in
 * this repo reach for constantly when writing hand-assembled `.S` probes:
 * C-preprocessor `#define` macros with several instructions joined by `;`
 * on one logical line, and a bare `#param` inside such a macro's body.
 * Found (#128, M1.4) via mutation-testing tests/spike/t9_simd_probe.S and
 * tests/spike/t12_synth_probe.S -- deliberately breaking a sentinel write
 * and expecting the corresponding test to fail, per this repo's own
 * testing convention, and finding that it DIDN'T: the checks those two
 * probes performed turned out to be dead code, silently, with no build
 * error or warning anywhere in the chain.
 *
 * TWO independent, compounding problems, demonstrated separately below:
 *
 * 1. `;` is an END-OF-LINE COMMENT character for this assembler/target,
 *    NOT a statement separator (unlike GNU `as` on many other targets/
 *    platforms, where `;` DOES separate multiple statements on one
 *    line -- which is exactly the behavior every `#define`-based macro
 *    in the affected probes assumed). A `#define` whose body joins
 *    several instructions with `;` therefore assembles to ONLY its FIRST
 *    instruction; everything after the first `;` on that (cpp-collapsed)
 *    line is silently treated as a comment and discarded. No error, no
 *    warning, from either cpp or the assembler.
 *
 * 2. Independently: a bare `#name` inside a `#define`'s body, where `name`
 *    is one of that macro's own parameters, is the C preprocessor's
 *    STRINGIFICATION operator -- it does NOT mean "immediate value"
 *    (AArch64 asm's own `#` sigil) when it happens to be written
 *    immediately before a parameter name. `#(name)` (parens right after
 *    `#`) is NOT affected -- only the bare `#name` spelling is. This
 *    turns e.g. `lsl x10, x10, #k` into `lsl x10, x10, "3"` after cpp
 *    expansion for `k=3` -- a quoted string where an immediate shift
 *    amount belongs.
 *
 * Combined, in the two affected probes: every multi-instruction `#define`
 * silently collapsed to its first instruction only (problem 1), so
 * problem 2's malformed operand (which would appear later on the same
 * logical line) never even got as far as the assembler to have a chance
 * of erroring on it. The net effect: tests/spike/t9_simd_probe.S's
 * per-register FP/SIMD comparison (T9CHK/T9POISONCHK) and
 * tests/spike/t12_synth_probe.S's heap-scratch/own-stack sentinel
 * comparisons (T12CHKH/T12CHKS) plus their corresponding sentinel WRITES
 * (T12HEAP/T12STACK) never actually executed their comparison/store logic
 * -- both tests could PASS regardless of whether the property they
 * claimed to check actually held. Fixed by converting all six to GNU
 * `.macro`/`.endm` (one instruction per line, `\param` substitution,
 * neither problem applies) -- the same style every OTHER macro in this
 * repo's `.S` probes (SETREG/CHKREG/POISON/CHKPOISON/POISONALL/
 * CHKPOISONALL/POISOND in t8_gpr_probe.S and t9_simd_probe.S) already
 * used, and which is unaffected by either problem.
 *
 * Repro, problem 1 (silent instruction-dropping -- the dangerous one:
 * this assembles CLEANLY, no error, no warning):
 *
 *   $ cc -arch arm64 -c docs/defects/m1-4-clang-as-semicolon-comment-and-hash-stringify.S -o /tmp/repro.o
 *   $ otool -tV /tmp/repro.o
 *   _probe1_only:
 *   0000000000000000	mov	x9, #0x1234
 *   0000000000000004	ret
 *   # PROBE1(3) should have assembled to FOUR instructions
 *   # (movz/movk/movk/str); only the movz survives.
 *
 * Repro, problem 2 (stringification -- shown separately via `cc -E`
 * rather than as a second function in this file: combining it into the
 * same translation unit as PROBE1 above would make the file fail to
 * build outright with "invalid operand for instruction" pointing at the
 * literal string `"3"`, once problem 1 is fixed on ITS OWN and no longer
 * masks this one -- which is itself informative: problem 2 alone is
 * loud, only the co-occurrence with problem 1 above is silent):
 *
 *   $ echo '#define PROBE2(k) lsl x10, x10, #k' > /tmp/p2.S
 *   $ echo 'PROBE2(3)' >> /tmp/p2.S
 *   $ cc -arch arm64 -E /tmp/p2.S | tail -1
 *   lsl x10, x10, "3"           # a string literal, not an immediate
 *
 * Toolchain: Apple clang (macOS arm64 integrated assembler), observed via
 * `cc` as invoked throughout this repo's build scripts.
 */

.text
.align 2

#define PROBE1(k)                     \
    movz x9, #(0x1234);               \
    movk x9, #(k), lsl #48;           \
    movk x9, #(k), lsl #0;            \
    str  x9, [x0, #(k*8)]

.globl _probe1_only
_probe1_only:
    PROBE1(3)
    ret
#undef PROBE1
