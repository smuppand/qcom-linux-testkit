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

TESTNAME="WiFi_Firmware_Driver"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Paths for both targets
KODIAK_FW="/lib/firmware/ath11k/WCN6750/hw1.0/qcm6490/wpss.mbn"
LEMANS_FW="/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin"

# Check firmware presence
if [ -f "$KODIAK_FW" ]; then
    log_info "Kodiak firmware detected: $KODIAK_FW"
    RPROC_PATH="$(find /sys/class/remoteproc/ -maxdepth 1 -name 'remoteproc*' | grep -E '[3-9]$' | head -n1)"
    [ -z "$RPROC_PATH" ] && log_fail_exit "$TESTNAME" "Remoteproc node not found for Kodiak"
    state=$(cat "$RPROC_PATH/state" 2>/dev/null)
    if [ "$state" != "running" ]; then
        log_info "Starting remoteproc: $RPROC_PATH"
        echo start > "$RPROC_PATH/state"
        sleep 2
        state=$(cat "$RPROC_PATH/state" 2>/dev/null)
        [ "$state" != "running" ] && log_fail_exit "$TESTNAME" "Failed to start remoteproc $RPROC_PATH"
    fi
    log_info "Remoteproc is running for Kodiak."
elif [ -f "$LEMANS_FW" ]; then
    log_info "Lemans firmware detected: $LEMANS_FW"
    if ! modprobe ath11k_pci; then
        log_fail_exit "$TESTNAME" "Failed to load ath11k_pci module."
    fi
    lsmod | grep -q ath11k_pci || log_fail_exit "$TESTNAME" "ath11k_pci module not loaded."
    log_info "ath11k_pci module loaded for Lemans."
else
    log_skip_exit "$TESTNAME" "WiFi firmware not found for known targets."
fi

log_pass_exit "$TESTNAME" "WiFi firmware and driver validation successful."
