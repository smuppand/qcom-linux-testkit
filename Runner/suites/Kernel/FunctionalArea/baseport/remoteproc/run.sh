#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

TESTNAME="remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Test -----------------------"
log_info "Enumerating remoteproc subsystems..."

#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

TESTNAME="remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"
log_info "=== Test Initialization ==="

log_info "Collecting remoteproc firmware list..."
firmware_output=$(cat /sys/class/remoteproc/remoteproc*/firmware 2>/dev/null)

if [ -z "$firmware_output" ]; then
    log_fail "No remoteproc firmware entries found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Checking for modem exclusion in count..."
expected=$(echo "$firmware_output" | grep -vc "modem")
log_info "Expected remoteprocs (excluding modem): $expected"

log_info "Checking current remoteproc state..."
running=$(grep -h ^ /sys/class/remoteproc/remoteproc*/state 2>/dev/null | grep -c "running")
log_info "Running remoteprocs: $running"

if [ "$running" -eq "$expected" ]; then
    log_pass "$TESTNAME : Test Passed - all remoteprocs are running"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed - expected $expected running, but got $running"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "------------------- Completed $TESTNAME Testcase ----------------------------"
