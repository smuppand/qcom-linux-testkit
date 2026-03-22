#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Robustly find and source init_env
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
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="irq"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Function to get the timer count
get_timer_count() {
    grep arch_timer /proc/interrupts
}

# Get the initial timer count
log_info "Initial timer count:"
initial_count=$(get_timer_count)
log_info "$initial_count"

# Wait for 20 seconds
sleep 20

# Get the timer count after 20 secs
log_info "Timer count after 20 secs:"
final_count=$(get_timer_count)
log_info "$final_count"

# Compare the initial and final counts
log_info "Comparing timer counts:"
while IFS= read -r line; do
    [ -n "$line" ] || continue

    cpu=$(printf '%s\n' "$line" | awk '{print $1}')
    initial_values=$(printf '%s\n' "$line" | awk '{for(i=2;i<=9;i++) print $i}')
    final_values=$(printf '%s\n' "$final_count" | awk -v cpu="$cpu" '$1 == cpu {for(i=2;i<=9;i++) print $i}')

    fail_test=false
    i=0

    while IFS= read -r initial_value; do
        [ -n "$initial_value" ] || continue

        final_value=$(printf '%s\n' "$final_values" | sed -n "$((i + 1))p")
        if [ "$initial_value" -lt "$final_value" ]; then
            log_pass "CPU $i: Timer count has incremented. Test PASSED"
        else
            log_fail "CPU $i: Timer count has not incremented. Test FAILED"
            fail_test=true
        fi
        i=$((i + 1))
    done <<EOF
$initial_values
EOF

    if [ "$fail_test" = false ]; then
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" > "$res_file"
        exit 0
    else
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi
done <<EOF
$initial_count
EOF
