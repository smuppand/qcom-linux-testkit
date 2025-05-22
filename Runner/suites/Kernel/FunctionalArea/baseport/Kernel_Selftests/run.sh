#!/bin/sh
#
# Kernel Selftests Validation Script for ARM64 (RB3GEN2)
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
while [ "$ROOT_DIR" != "/" ]; do
    if [ -d "$ROOT_DIR/utils" ] && [ -d "$ROOT_DIR/suites" ]; then
        break
    fi
    ROOT_DIR=$(dirname "$ROOT_DIR")
done

if [ ! -d "$ROOT_DIR/utils" ] || [ ! -f "$ROOT_DIR/utils/functestlib.sh" ]; then
    echo "[ERROR] Could not detect testkit root (missing utils/ or functestlib.sh)" >&2
    exit 1
fi

TOOLS="$ROOT_DIR/utils"
INIT_ENV="$ROOT_DIR/init_env"
FUNCLIB="$TOOLS/functestlib.sh"

[ -f "$INIT_ENV" ] && . "$INIT_ENV"
. "$FUNCLIB"

__RUNNER_SUITES_DIR="${__RUNNER_SUITES_DIR:-$ROOT_DIR/suites}"

TESTNAME="Kernel_Selftests"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

SELFTESTS_DIR="/kselftest"
WHITELIST_FILE="./enabled_tests.list"
ARCH="$(uname -m)"
SKIP_LIST="x86 powerpc s390 mips sparc"

pass=0
fail=0
skip=0

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "-----------------------------------------------------------------------------------------"

check_dependencies find

if [ ! -d "$SELFTESTS_DIR" ]; then
    log_fail "[$TESTNAME] Selftests directory not found: $SELFTESTS_DIR"
    echo "FAIL ALL_SELFTESTS" > "$res_file"
    exit 1
fi

if [ ! -f "$WHITELIST_FILE" ]; then
    log_fail "[$TESTNAME] Whitelist file not found: $WHITELIST_FILE"
    exit 1
fi

rm -f ./*.log "$res_file"
echo "SUITE: $TESTNAME" > "$res_file"

ENABLED_TESTS=$(grep -vE '^\s*#|^\s*$' "$WHITELIST_FILE")

for testname in $ENABLED_TESTS; do
    testdir="$SELFTESTS_DIR/$testname"
    if [ ! -d "$testdir" ]; then
        log_skip "[$TESTNAME] Test directory not found: $testname"
        echo "SKIP $testname" >> "$res_file"
        skip=$((skip+1))
        continue
    fi

    for arch in $SKIP_LIST; do
        if [ "$testname" = "$arch" ]; then
            log_skip "[$TESTNAME] Skipping $testname selftest (not for $ARCH)"
            echo "SKIP $testname" >> "$res_file"
            skip=$((skip+1))
            continue 2
        fi
    done

    if [ -x "$testdir/run_test.sh" ]; then
        log_info "[$TESTNAME] Running $testname/run_test.sh"
        if "$testdir/run_test.sh" > "${testname}.log" 2>&1; then
            log_pass "[$TESTNAME] $testname: PASS"
            echo "PASS $testname" >> "$res_file"
            pass=$((pass+1))
        else
            log_fail "[$TESTNAME] $testname: FAIL (see ${testname}.log)"
            echo "FAIL $testname" >> "$res_file"
            fail=$((fail+1))
        fi
    else
        testbins=$(find "$testdir" -maxdepth 1 -type f -executable -name '*test')
        if [ -n "$testbins" ]; then
            for bin in $testbins; do
                binname=$(basename "$bin")
                log_info "[$TESTNAME] Running $testname/$binname"
                if "$bin" > "${testname}_${binname}.log" 2>&1; then
                    log_pass "[$TESTNAME] $testname/$binname: PASS"
                    echo "PASS $testname/$binname" >> "$res_file"
                    pass=$((pass+1))
                else
                    log_fail "[$TESTNAME] $testname/$binname: FAIL (see ${testname}_${binname}.log)"
                    echo "FAIL $testname/$binname" >> "$res_file"
                    fail=$((fail+1))
                fi
            done
        else
            log_skip "[$TESTNAME] No runnable test found in $testname"
            echo "SKIP $testname" >> "$res_file"
            skip=$((skip+1))
        fi
    fi
done

log_info "[$TESTNAME] Summary: PASSED=$pass FAILED=$fail SKIPPED=$skip"
echo "SUMMARY PASS=$pass FAIL=$fail SKIP=$skip" >> "$res_file"

if [ "$fail" -eq 0 ]; then
    log_pass "[$TESTNAME] All selected selftests PASSED!"
    exit 0
else
    log_fail "[$TESTNAME] Some selftests FAILED. See logs."
    exit 1
fi
