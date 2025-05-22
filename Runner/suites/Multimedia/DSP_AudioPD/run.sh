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

TESTNAME="DSP_AudioPD"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

sync
sleep 1


log_info "Checking if dependency binary is available"
check_dependencies adsprpcd

adsprpcd &
PID=$!

if [ -z "$PID" ]; then
  echo "Failed to start the binary"
  exit 1
else
  echo "Binary is running successfully"
fi

check_stack_trace() {
	local pid=$1
	if cat /proc/$pid/stack 2>/dev/null | grep -q "do_sys_poll"; then
		return 0
	else
		return 1
	fi
}

# Print overall test result
if check_stack_trace "$PID"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "Kill the process"
if kill -0 "$PID" 2>/dev/null; then
	kill -9 "$PID"
	wait "$PID"
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
