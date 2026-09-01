#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
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

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
TESTNAME="DeviceTree_HW_Capability_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME"

dt_hw_capability_parse_args "$@"
parse_status=$?
if [ "$parse_status" -ne 0 ]; then
    if [ "$parse_status" -eq 2 ]; then
        exit 0
    fi
    echo "[ERROR] Usage: ./run.sh [--area all|identity,boot,cpu-memory,interrupts,fabric,storage,usb,pcie,network,multimedia,remoteproc,security,health] [--list-areas]" >&2
    exit 2
fi

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create result directory $RESULT_DIR"
fi

# DT helper discovery uses mktemp. Keep all temporary files in the testcase
# directory instead of inheriting a target-specific TMPDIR.
TMPDIR="$SCRIPT_DIR"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    awk basename cp date dirname dmesg find grep mkdir mktemp readlink rm sed sort tr wc; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

if ! DT_ROOT=$(dt_runtime_root); then
    test_result_finish "SKIP" "$TESTNAME SKIP: runtime device tree is not exposed"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Validation areas: $DTRHC_AREAS"

if ! dt_validate_runtime_hardware_capabilities "$DT_ROOT" "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: DT capability validation could not complete"
fi

test_result_finish
