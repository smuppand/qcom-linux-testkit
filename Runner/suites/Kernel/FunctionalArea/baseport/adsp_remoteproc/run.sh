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

TESTNAME="adsp_remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

sync
sleep 1

# Get the firmware output and find the position of adsp
log_info "Checking for firmware"
firmware_output=$(cat /sys/class/remoteproc/remoteproc*/firmware)
adsp_position=$(echo "$firmware_output" | grep -n "adsp" | cut -d: -f1)

# Adjust the position to match the remoteproc numbering (starting from 0)
remoteproc_number=$((adsp_position - 1))

# Construct the remoteproc path based on the adsp position
remoteproc_path="/sys/class/remoteproc/remoteproc${remoteproc_number}"
log_info "Remoteproc node is $remoteproc_path"
# Execute command 1 and check if the output is "running"
state1=$(cat ${remoteproc_path}/state)

if [ "$state1" != "running" ]; then
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi

# Execute command 2 (no output expected)
log_info "Stopping remoteproc"
echo stop > ${remoteproc_path}/state

# Execute command 3 and check if the output is "offline"
state3=$(cat ${remoteproc_path}/state)
if [ "$state3" != "offline" ]; then
    log_fail "adsp stop failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
else
    log_pass "adsp stop successful"
fi
log_info "Restarting remoteproc"
# Execute command 4 (no output expected)
echo start > ${remoteproc_path}/state

# Execute command 5 and check if the output is "running"
state5=$(cat ${remoteproc_path}/state)
if [ "$state5" != "running" ]; then
    log_fail "adsp start failed"
    echo "$TESTNAME FAIL" > "$res_file" 
    exit 1
fi

# If all checks pass, print "PASS"
echo "adsp PASS"
log_pass "adsp PASS"
echo "$TESTNAME PASS" > "$res_file"
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
