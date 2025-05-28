#!/bin/sh
#
# Kernel Selftests Validation Script for ARM64 (RB3GEN2)
#
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Dynamically locate and source init_env (robust for any repo structure)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090
. "$TOOLS/functestlib.sh"

TESTNAME="Kernel_Selftests"
test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_fail "$TESTNAME : Test directory not found."
    echo "FAIL $TESTNAME" > "./$TESTNAME.run"
    exit 1
fi

cd "$test_path" || exit 1

res_file="./$TESTNAME.res"
summary_file="./$TESTNAME.run"
whitelist="./enabled_tests.list"
selftest_dir="/kselftest"
arch="$(uname -m)"
skip_arch="x86 powerpc mips sparc"

pass=0
fail=0
skip=0

rm -f "$res_file" "$summary_file"
echo "SUITE: $TESTNAME" > "$res_file"

log_info "Starting $TESTNAME..."

check_dependencies "find" "/kselftest"

if [ ! -f "$whitelist" ]; then
    log_fail "$TESTNAME: whitelist $whitelist not found"
    echo "FAIL $TESTNAME" > "$summary_file"
    exit 1
fi

while IFS= read -r test || [ -n "$test" ]; do
    case "$test" in
        ''|\#*) continue ;; # Skip blanks and comments
    esac

    # If test is architecture-specific, skip if not supported
    for a in $skip_arch; do
        if [ "$test" = "$a" ]; then
            log_skip "$test skipped on $arch"
            echo "SKIP $test (unsupported arch)" >> "$res_file"
            skip=$((skip+1))
            continue 2
        fi
    done

    # Check for directory/binary (e.g., timers/thread_test)
    case "$test" in
        */*)
            test_dir="${test%%/*}"
            test_bin="${test#*/}"
            bin_path="$selftest_dir/$test_dir/$test_bin"
            if [ ! -d "$selftest_dir/$test_dir" ]; then
                log_skip "$test_dir not found"
                echo "SKIP $test (directory not found)" >> "$res_file"
                skip=$((skip+1))
                continue
            fi
            if [ -x "$bin_path" ]; then
                log_info "Running $test_dir/$test_bin"
                if timeout 300 "$bin_path" > "${test_dir}_${test_bin}.log" 2>&1; then
                    log_pass "$test: passed"
                    echo "PASS $test" >> "$res_file"
                    pass=$((pass+1))
                else
                    log_fail "$test: failed"
                    echo "FAIL $test" >> "$res_file"
                    fail=$((fail+1))
                fi
            else
                log_skip "$test: not found or not executable"
                echo "SKIP $test (not found or not executable)" >> "$res_file"
                skip=$((skip+1))
            fi
            continue
            ;;
    esac

    # Standard: just the directory (run run_test.sh or all *test bins)
    test_dir="$selftest_dir/$test"
    if [ ! -d "$test_dir" ]; then
        log_skip "$test not found"
        echo "SKIP $test (not found)" >> "$res_file"
        skip=$((skip+1))
        continue
    fi

    if [ -x "$test_dir/run_test.sh" ]; then
        log_info "Running $test/run_test.sh"
        if timeout 300 "$test_dir/run_test.sh" > "$test.log" 2>&1; then
            log_pass "$test passed"
            echo "PASS $test" >> "$res_file"
            pass=$((pass+1))
        else
            log_fail "$test failed"
            echo "FAIL $test" >> "$res_file"
            fail=$((fail+1))
        fi
    else
        found_bin=0
        for bin in "$test_dir"/*test; do
            [ -f "$bin" ] && [ -x "$bin" ] || continue
            found_bin=1
            binname=$(basename "$bin")
            log_info "Running $test/$binname"
            if timeout 300 "$bin" > "${test}_${binname}.log" 2>&1; then
                log_pass "$test/$binname passed"
                echo "PASS $test/$binname" >> "$res_file"
                pass=$((pass+1))
            else
                log_fail "$test/$binname failed"
                echo "FAIL $test/$binname" >> "$res_file"
                fail=$((fail+1))
            fi
        done
        if [ "$found_bin" -eq 0 ]; then
            log_skip "$test: no test binaries"
            echo "SKIP $test (no test binaries)" >> "$res_file"
            skip=$((skip+1))
        fi
    fi
done < "$whitelist"

echo "SUMMARY PASS=$pass FAIL=$fail SKIP=$skip" >> "$res_file"

if [ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]; then
    echo "PASS $TESTNAME" > "$summary_file"
    log_pass "$TESTNAME: all tests passed"
else
    echo "FAIL $TESTNAME" > "$summary_file"
    log_fail "$TESTNAME: one or more tests failed"
fi

exit 0
