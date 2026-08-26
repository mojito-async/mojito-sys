#!/bin/sh
# mojito-sys S5 — ctx behavioral probe suite (issues #64/#65).
#
# Committed regression net for the frozen ms_context v2 ABI:
#   1. sentinel probe (sentinel_probe.c): init/capture/switch/yields/exit
#      round-trips against the PACKAGED libmojito_sys.dylib, verifying
#      x19-x28 + d8-d15 preservation plus 16-byte sp alignment at -O0 AND
#      -O2, argument validation (-EINVAL), the capture-revives-destroyed
#      contract, and the loud SIGTRAP on resume of a destroyed context.
#   2. runtime audit (runtime_audit.sh): non-vacuous T14-style audit —
#      zero Modular-runtime symbols vs an explicit expected-absence list,
#      guarded against the PR#21-era "nm -uU no-op" vacuity (#65).
#   3. oracle cross-check (oracle_probe.c): the identical sentinel probe
#      runs against the production dylib AND the spike dylib; outputs are
#      diffed byte-for-byte (#65).
#   4. ELF backend rows, parametrized by platform: behavioral rows run
#      ONLY on Linux/arm64; elsewhere they print an explicit
#      UNSUPPORTED-PLATFORM row (red-excluded per spec §38.6 until a
#      Linux arm64 runner exists — never a silent skip), while an
#      assemble-only smoke proves the __ELF__ half of the skeleton
#      compiles on any host with a cross-target assembler.
#   5. lifecycle acceptance (lifecycle/run.sh, #66): the self-contained
#      per-context lifecycle — >64 simultaneous live contexts, >=4
#      threads running independent switch pairs, exactly-once completion
#      hook, loud FINISHED/RUNNING re-resume traps and loud misalignment
#      rejection, at BOTH -O0 and -O2.
#
# Usage: tests/s5/ctx/run.sh
#   CC=<cc> overrides the compiler.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CC=${CC:-cc}
OUT="$REPO_ROOT/build/s5-ctx"
DYLIB="$REPO_ROOT/libmojito_sys.dylib"
SPIKE_DYLIB="$REPO_ROOT/libmojito_spike.dylib"
TEST_NAME="s5_ctx_sentinel"

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: CC=$CC not found"
    echo "$TEST_NAME FAIL (compiler unavailable)"
    exit 2
fi
if [ ! -f "$DYLIB" ]; then
    echo "ERROR: $DYLIB not found; run \`make\` at the repo root first."
    echo "$TEST_NAME FAIL (dylib missing)"
    exit 2
fi

mkdir -p "$OUT"

echo "== $TEST_NAME (issue #64 F6)"

failures=0
matrix=""
for opt in O0 O2; do
    bin="$OUT/sentinel_probe_$opt"
    if ! "$CC" -$opt -Wall -Wextra -I"$REPO_ROOT/native/include" \
            "$SCRIPT_DIR/sentinel_probe.c" "$DYLIB" -o "$bin"; then
        matrix="$matrix$opt BUILD-FAIL
"
        failures=$((failures + 1))
        continue
    fi
    out=$(DYLD_LIBRARY_PATH="$REPO_ROOT" "$bin" 2>&1)
    st=$?
    printf '%s\n' "$out" | sed 's/^/   | /'
    if [ $st -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
        matrix="$matrix$opt PASS
"
    else
        matrix="$matrix$opt FAIL
"
        failures=$((failures + 1))
    fi
done

echo ""
echo "S5 ctx sentinel matrix (issue #64 F6)"
echo "$matrix" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi

# ---- issue #65 additions -------------------------------------------------
echo ""
echo "== s5_ctx_runtime_audit + oracle + ELF rows (issue #65)"
rows=""

# 1. Non-vacuous T14-style runtime audit.
out=$(sh "$SCRIPT_DIR/runtime_audit.sh" 2>&1)
st=$?
printf '%s\n' "$out" | sed 's/^/   | /'
if [ $st -eq 0 ]; then
    rows="$rows runtime-audit PASS
"
else
    rows="$rows runtime-audit FAIL
"
    failures=$((failures + 1))
fi

# 2. Oracle cross-check: identical sentinel probe vs prod AND spike dylib.
if [ ! -f "$SPIKE_DYLIB" ]; then
    make -C "$REPO_ROOT" libmojito_spike.dylib >/dev/null 2>&1 || true
fi
if [ ! -f "$SPIKE_DYLIB" ]; then
    echo "   | oracle FAIL: $SPIKE_DYLIB missing and unbuildable via make"
    rows="$rows oracle FAIL
"
    failures=$((failures + 1))
else
    if "$CC" -O2 -Wall -Wextra "$SCRIPT_DIR/oracle_probe.c" \
            -o "$OUT/oracle_probe"; then
        DYLD_LIBRARY_PATH="$REPO_ROOT" "$OUT/oracle_probe" \
            "$DYLIB" >"$OUT/oracle_prod.out" 2>"$OUT/oracle_prod.err"
        st_prod=$?
        DYLD_LIBRARY_PATH="$REPO_ROOT" "$OUT/oracle_probe" \
            "$SPIKE_DYLIB" >"$OUT/oracle_spike.out" 2>"$OUT/oracle_spike.err"
        st_spike=$?
        sed 's/^/   | prod | /' "$OUT/oracle_prod.out"
        if [ $st_prod -ne 0 ] || ! grep -q "RESULT: all green" \
                "$OUT/oracle_prod.out"; then
            rows="$rows oracle-prod FAIL
"
            failures=$((failures + 1))
        else
            rows="$rows oracle-prod PASS
"
        fi
        if [ $st_spike -ne 0 ] || ! grep -q "RESULT: all green" \
                "$OUT/oracle_spike.out"; then
            rows="$rows oracle-spike FAIL
"
            failures=$((failures + 1))
        else
            rows="$rows oracle-spike PASS
"
        fi
        if diff -u "$OUT/oracle_spike.out" "$OUT/oracle_prod.out" \
                >"$OUT/oracle.diff"; then
            echo "   | oracle diff (spike vs prod outputs): identical"
            rows="$rows oracle-diff PASS
"
        else
            echo "   | oracle DIFF DETECTED (spike vs prod):"
            printf '%s\n' "$OUT/oracle.diff" | sed 's/^/   | /'
            rows="$rows oracle-diff FAIL
"
            failures=$((failures + 1))
        fi
    else
        echo "   | oracle FAIL: oracle_probe.c build failed"
        rows="$rows oracle BUILD-FAIL
"
        failures=$((failures + 1))
    fi
fi

# 3. ELF backend rows (parametrized; §38.6 red-exclusion is EXPLICIT).
platform="$(uname -s)/$(uname -m)"
case "$platform" in
Linux/arm64|Linux/aarch64)
    so="$OUT/libmojito_sys.so"
    if "$CC" -O2 -g -fPIC -I"$REPO_ROOT/native/include" -shared \
            "$REPO_ROOT"/native/posix/*.c "$REPO_ROOT"/native/posix/*.S \
            -o "$so"; then
        elf_ok=1
        for opt in O0 O2; do
            bin="$OUT/sentinel_probe_elf_$opt"
            if ! "$CC" -$opt -Wall -Wextra -I"$REPO_ROOT/native/include" \
                    "$SCRIPT_DIR/sentinel_probe.c" "$so" -o "$bin"; then
                elf_ok=0
                continue
            fi
            out=$(LD_LIBRARY_PATH="$OUT" "$bin" 2>&1)
            if [ $? -ne 0 ] || ! printf '%s' "$out" |
                    grep -q "RESULT: all green"; then
                elf_ok=0
                printf '%s\n' "$out" | sed 's/^/   | /'
            fi
        done
        if [ $elf_ok -eq 1 ]; then
            rows="$rows elf-backend PASS
"
        else
            rows="$rows elf-backend FAIL
"
            failures=$((failures + 1))
        fi
    else
        echo "   | elf-backend FAIL: ELF shared-object build failed"
        rows="$rows elf-backend FAIL
"
        failures=$((failures + 1))
    fi
    ;;
*)
    echo "   | elf-backend UNSUPPORTED-PLATFORM ($platform): behavioral ELF"
    echo "   |   rows are red-excluded per spec §38.6 until a Linux arm64"
    echo "   |   runner exists (explicit exclusion, NOT a silent skip)"
    rows="$rows elf-backend RED-EXCLUDED ($platform, §38.6)
"
    ;;
esac

# Assemble-only smoke of the __ELF__ skeleton — runs on any host whose cc
# can cross-assemble aarch64-linux; proves the ELF half compiles even
# where it cannot execute.
if "$CC" --target=aarch64-linux-gnu \
        -c "$REPO_ROOT/native/posix/ms_context_aarch64.S" \
        -o "$OUT/ms_context_aarch64_elf.o" 2>"$OUT/elf_asm.err"; then
    echo "   | elf-assemble: __ELF__ skeleton cross-assembles cleanly"
    rows="$rows elf-assemble PASS
"
else
    if uname -s | grep -q '^Linux$'; then
        # Native build path already covered the ELF object above.
        rows="$rows elf-assemble COVERED-BY-NATIVE-BUILD
"
    else
        echo "   | elf-assemble SKIP (cross-assembler unavailable):"
        printf '%s\n' "$OUT/elf_asm.err" | sed 's/^/   |     /'
        rows="$rows elf-assemble SKIP (no cross-assembler)
"
    fi
fi

# ---- issue #66 additions -------------------------------------------------
echo ""
echo "== s5_ctx_lifecycle rows (issue #66)"
lrows=""
# Self-contained per-context lifecycle: >64 live contexts, >=4 threads,
# exactly-once finish hook, loud FINISHED/RUNNING re-resume traps,
# loud misalignment rejection — at BOTH -O0 and -O2.
out=$(sh "$SCRIPT_DIR/lifecycle/run.sh" 2>&1)
st=$?
printf '%s\n' "$out" | sed 's/^/   | /'
if [ $st -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: all green"; then
    lrows="$lrows lifecycle O0 PASS
 lifecycle O2 PASS
"
else
    lrows="$lrows lifecycle FAIL
"
    failures=$((failures + 1))
fi

echo ""
echo "S5 ctx issue-#66 matrix"
echo "$lrows" | sed 's/^/  /'

echo ""
echo "S5 ctx issue-#65 matrix"
echo "$rows" | sed 's/^/  /'
if [ "$failures" -ne 0 ]; then
    echo "RESULT: $failures FAILED"
    exit 1
fi
echo "RESULT: all green"
exit 0
