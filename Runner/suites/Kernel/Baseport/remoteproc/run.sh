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
RES_FILE="./$TESTNAME.res"

# write_result <PASS|FAIL|SKIP>
# Writes the single result line consumed by send-to-lava.sh. Returns the
# status of the write operation.
write_result() {
    result="$1"
    printf '%s %s\n' "$TESTNAME" "$result" >"$RES_FILE"
}

failures=0
runtime_file="$SCRIPT_DIR/remoteproc_runtime.log"
: >"$runtime_file"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

if ! list_remoteproc_instances "$runtime_file"; then
    log_skip "$TESTNAME SKIP: no runtime remoteproc instance is registered"
    write_result "SKIP"
    exit 0
fi

while IFS='|' read -r remoteproc_path remoteproc_name remoteproc_firmware remoteproc_state; do
    [ -n "$remoteproc_path" ] || continue

    remoteproc_driver="<not exposed>"
    if [ -e "$remoteproc_path/device/driver" ]; then
        remoteproc_driver=$(basename "$(readlink -f "$remoteproc_path/device/driver")")
    fi

    log_info "Remoteproc $(basename "$remoteproc_path"), driver=$remoteproc_driver, name=$remoteproc_name, firmware=$remoteproc_firmware, state=$remoteproc_state"

    if [ -z "$remoteproc_name" ] || [ -z "$remoteproc_firmware" ] || [ "$remoteproc_state" = "unknown" ]; then
        log_fail "Remoteproc sysfs attributes are incomplete for $remoteproc_path"
        failures=$((failures + 1))
        continue
    fi

    case "$remoteproc_state" in
        running|attached)
            log_pass "Remoteproc state is valid: $remoteproc_state"
            ;;
        offline)
            log_pass "Remoteproc is offline, valid for a non-autoboot processor: $remoteproc_name"
            ;;
        crashed)
            log_fail "Remoteproc is crashed: $remoteproc_name"
            failures=$((failures + 1))
            ;;
        *)
            log_fail "Remoteproc has an unexpected state: $remoteproc_state"
            failures=$((failures + 1))
            ;;
    esac

    if firmware_path=$(find_image_firmware "$remoteproc_firmware"); then
        log_pass "Image-provided firmware is present: $firmware_path"
    else
        log_info "Firmware is not exposed below standard firmware paths: $remoteproc_firmware"
    fi
done <"$runtime_file"

scan_dmesg_errors "$SCRIPT_DIR" "remoteproc|qcom.*pas|qcom_q6v5" "subsys-restart|not a crash|firmware.*already" || true
if [ -s "$SCRIPT_DIR/dmesg_errors.log" ]; then
    log_fail "Remoteproc and Qualcomm PAS kernel errors are recorded in dmesg_errors.log"
    failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
    log_pass "$TESTNAME PASS"
    write_result "PASS"
else
    log_fail "$TESTNAME FAIL: failures=$failures"
    write_result "FAIL"
fi
exit 0
