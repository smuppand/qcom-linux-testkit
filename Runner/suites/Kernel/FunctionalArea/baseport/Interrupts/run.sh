#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
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

TESTNAME="Interrupts"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

sync
sleep 1

# Function to get the timer count
get_timer_count() {
    cat /proc/interrupts | grep arch_timer
}

# Get the initial timer count
echo "Initial timer count:"
initial_count=$(get_timer_count)
echo "$initial_count"

# Wait for 2 minutes
sleep 120

# Get the timer count after 2 minutes
echo "Timer count after 2 minutes:"
final_count=$(get_timer_count)
echo "$final_count"

# Compare the initial and final counts
echo "Comparing timer counts:"
echo "$initial_count" | while read -r line; do
    cpu=$(echo "$line" | awk '{print $1}')
    initial_values=$(echo "$line" | awk '{for(i=2;i<=9;i++) print $i}')
    final_values=$(echo "$final_count" | grep "$cpu" | awk '{for(i=2;i<=9;i++) print $i}')
    
    fail_test=false
    initial_values_list=$(echo "$initial_values" | tr ' ' '\n')
    final_values_list=$(echo "$final_values" | tr ' ' '\n')
    
    i=0
    echo "$initial_values_list" | while read -r initial_value; do
        final_value=$(echo "$final_values_list" | sed -n "$((i+1))p")
        if [ "$initial_value" -lt "$final_value" ]; then
            echo "CPU $i: Timer count has incremented. Test PASSED"
            log_pass "CPU $i: Timer count has incremented. Test PASSED"
        else
            echo "CPU $i: Timer count has not incremented. Test FAILED"
            log_fail "CPU $i: Timer count has not incremented. Test FAILED"
            fail_test=true
        fi
        i=$((i+1))
    done
    echo $fail_test
    if [ "$fail_test" = false ]; then
        log_pass "$TESTNAME : Test Passed"
	echo "$TESTNAME PASS" > "$res_file"
    else
        log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > "$res_file"
    fi
done
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
