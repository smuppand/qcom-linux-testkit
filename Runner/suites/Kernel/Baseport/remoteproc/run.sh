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

TESTNAME="remoteproc"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

runtime_file="$SCRIPT_DIR/remoteproc_runtime.log"
: >"$runtime_file"

if ! test_result_init "$TESTNAME" "$RES_FILE"; then
    log_error "Could not initialize the result file: $RES_FILE"
    exit 1
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

if ! list_remoteproc_instances "$runtime_file"; then
    test_result_record "SKIP" "No runtime remoteproc instance is registered under /sys/class/remoteproc"
    test_result_finish
fi

while IFS='|' read -r remoteproc_path remoteproc_name remoteproc_firmware remoteproc_state; do
    [ -n "$remoteproc_path" ] || continue

    remoteproc_driver="<not exposed>"
    if [ -e "$remoteproc_path/device/driver" ]; then
        remoteproc_driver=$(basename "$(readlink -f "$remoteproc_path/device/driver")")
    fi

    log_info "Remoteproc $(basename "$remoteproc_path"), driver=$remoteproc_driver, name=$remoteproc_name, firmware=$remoteproc_firmware, state=$remoteproc_state"

    if [ -z "$remoteproc_name" ] || [ -z "$remoteproc_firmware" ] || [ "$remoteproc_state" = "unknown" ]; then
        test_result_record "FAIL" "Remoteproc sysfs attributes are incomplete: path=$remoteproc_path name=${remoteproc_name:-missing} firmware=${remoteproc_firmware:-missing} state=$remoteproc_state"
        continue
    fi

    case "$remoteproc_state" in
        running|suspended|attached)
            test_result_record "PASS" "Remoteproc is in a valid active state: name=$remoteproc_name state=$remoteproc_state"
            ;;
        offline|detached)
            test_result_record "PASS" "Remoteproc is in a valid inactive state: name=$remoteproc_name state=$remoteproc_state"
            ;;
        crashed)
            test_result_record "FAIL" "Remoteproc is crashed and requires firmware or driver recovery: name=$remoteproc_name path=$remoteproc_path"
            ;;
        *)
            test_result_record "FAIL" "Remoteproc exposes an unexpected state: name=$remoteproc_name state=$remoteproc_state path=$remoteproc_path"
            ;;
    esac

    if firmware_path=$(find_image_firmware "$remoteproc_firmware"); then
        test_result_record "PASS" "Image-provided remoteproc firmware is present: $firmware_path"
    else
        log_info "Firmware is not exposed below standard firmware paths: $remoteproc_firmware"
    fi
done <"$runtime_file"

scan_dmesg_errors "$SCRIPT_DIR" "remoteproc|qcom.*pas|qcom_q6v5" "subsys-restart|not a crash|firmware.*already" || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Remoteproc kernel-health validation is unavailable because the target did not expose a readable kernel log, artifact=$SCRIPT_DIR/dmesg_access.log"
elif [ -s "$SCRIPT_DIR/dmesg_errors.log" ]; then
    test_result_record "FAIL" "Remoteproc or Qualcomm PAS kernel errors were detected, artifact=$SCRIPT_DIR/dmesg_errors.log"
else
    test_result_record "PASS" "No non-benign remoteproc or Qualcomm PAS kernel errors were found"
fi

test_result_finish
