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

TESTNAME="hotplug"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

sync
sleep 1

check_cpu_status() {
    cat /sys/devices/system/cpu/cpu*/online
}
op=0
offline_cpu() {
    echo 0 > "/sys/devices/system/cpu/$1/online"
    op=$(cat "/sys/devices/system/cpu/$1/online")
    if [ "$op" -ne 1 ]; then
        log_pass "/sys/devices/system/cpu/$1/online is offline as expected"
    fi
}

online_cpu() {
    echo 1 > "/sys/devices/system/cpu/$1/online"
    op=$(cat "/sys/devices/system/cpu/$1/online")
    if [ "$op" -ne 0 ]; then
        log_pass "/sys/devices/system/cpu/$1/online is online as expected"
    fi
}

log_info "Initial CPU status:"
check_cpu_status | tee -a "$LOG_FILE"

test_passed=true
for cpu in /sys/devices/system/cpu/cpu[0-7]*; do
    cpu_id=$(basename "$cpu")

    log_info "Offlining $cpu_id"
    offline_cpu "$cpu_id"
    sleep 1

    online_status=$(cat /sys/devices/system/cpu/$cpu_id/online)
    if [ "$online_status" -ne 0 ]; then
        log_fail "Failed to offline $cpu_id"
        test_passed=false
    fi

    log_info "Onlining $cpu_id"
    online_cpu "$cpu_id"
    sleep 1

    online_status=$(cat /sys/devices/system/cpu/$cpu_id/online)
    if [ "$online_status" -ne 1 ]; then
        log_fail "Failed to online $cpu_id"
        test_passed=false
    fi
done

log_info "Final CPU status:"
check_cpu_status | tee -a "$LOG_FILE"

# Print overall test result
if [ "$test_passed" = true ]; then
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
