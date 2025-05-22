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

TESTNAME="Reboot_health_check"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

sync
sleep 1

# Directory for health check files
HEALTH_DIR="/var/reboot_health"
RETRY_FILE="$HEALTH_DIR/reboot_retry_count"
MAX_RETRIES=3

# Make sure health directory exists
mkdir -p "$HEALTH_DIR"

# Initialize retry count if not exist
if [ ! -f "$RETRY_FILE" ]; then
    echo "0" > "$RETRY_FILE"
fi

# Read current retry count
RETRY_COUNT=$(cat "$RETRY_FILE")

log_info "--------------------------------------------"
log_info "Boot Health Check Started - $(date)" 
log_info "Current Retry Count: $RETRY_COUNT"

# Health Check: You can expand this check
if [ "$(whoami)" = "root" ]; then
    log_pass "System booted successfully and root shell obtained."
    log_info "Test Completed Successfully after $RETRY_COUNT retries."
    
    # Optional: clean retry counter after success
    echo "0" > "$RETRY_FILE"
    
    exit 0
else
    log_fail "Root shell not available!"
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "$RETRY_COUNT" > "$RETRY_FILE"
    
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        log_error "[ERROR] Maximum retries ($MAX_RETRIES) reached. Stopping test."
        exit 1
    else
        log_info "Rebooting system for retry #$RETRY_COUNT..."
        sync
        sleep 2
        reboot -f
    fi
fi
