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
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_pkg_provider.sh"

TESTNAME="RMTFS_Partition_Read_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
PARTITIONS="${RMTFS_PARTITIONS:-modemst1 modemst2 fsc fsg}"

usage() {
    echo "Usage: $0 [--partitions 'modemst1 modemst2 ...']"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --partitions)
            if [ "$#" -lt 2 ]; then
                log_fail "--partitions requires a value"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            PARTITIONS="$2"
            shift 2
            ;;
        --partitions=*)
            PARTITIONS=${1#--partitions=}
            shift
            ;;
        -h|--help)
            usage
            echo "$TESTNAME SKIP" > "$RES_FILE"
            exit 0
            ;;
        *)
            log_fail "Unknown argument: $1"
            usage
            echo "$TESTNAME FAIL" > "$RES_FILE"
            exit 1
            ;;
    esac
done

rm -f "$RES_FILE"

# shellcheck disable=SC2317
cleanup_on_exit() {
    rmtfs_runtime_cleanup >/dev/null 2>&1 || true
}

trap cleanup_on_exit 0
trap 'exit 1' 1 2 15

RMTFS_RUNTIME_DIR="$SCRIPT_DIR/rmtfs_runtime"
rmtfs_runtime_prepare "$RMTFS_RUNTIME_DIR"
PREPARE_RC=$?

if [ "$PREPARE_RC" -eq 2 ]; then
    log_skip "$TESTNAME SKIP: RMTFS is not applicable on this platform"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

if [ "$PREPARE_RC" -ne 0 ]; then
    log_fail "$TESTNAME FAIL: unable to prepare the RMTFS runtime snapshot"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

find_partition() {
    fp_label="$1"
    for fp_dir in /dev/disk/by-partlabel /dev/disk/by-name /dev/block/by-name /dev/block/platform/*/by-name; do
        [ -e "$fp_dir/$fp_label" ] || continue
        fp_resolved=$(readlink -f "$fp_dir/$fp_label" 2>/dev/null || true)
        if [ -z "$fp_resolved" ]; then
            fp_resolved="$fp_dir/$fp_label"
        fi
        printf '%s\n' "$fp_resolved"
        return 0
    done
    return 1
}

OS_ID=$(pkg_detect_os_id 2>/dev/null || echo unknown)
ERROR_LOG="$SCRIPT_DIR/partition_read_errors.log"
rm -f "$ERROR_LOG" "$RES_FILE"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FOUND_COUNT=0
log_info "Starting $TESTNAME on OS=$OS_ID"
log_info "Reads are limited to one 512-byte sector and partition contents are never logged"

if [ "$RMTFS_MODULE_LOAD_ATTEMPTED" -eq 1 ] && \
   [ "$RMTFS_MODULE_LOAD_FAILED" -eq 1 ]; then
    log_fail "$TESTNAME FAIL: the initially unloaded rmtfs_mem module could not be loaded"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 1 ]; then
    rmtfs_start_service_if_available || true
fi
PARTITION_MODE=0
PARTITION_MODE_KNOWN=0
if rmtfs_process_running rmtfs; then
    if rmtfs_daemon_cmdline_readable; then
        PARTITION_MODE_KNOWN=1
        if rmtfs_daemon_uses_partitions; then
            PARTITION_MODE=1
            log_info "The running rmtfs daemon uses raw partition mode"
        else
            log_info "The running rmtfs daemon uses directory-backed storage"
        fi
    else
        log_warn "The running rmtfs daemon command line is not readable, storage mode could not be determined"
    fi
fi

for partition in $PARTITIONS; do
    device=$(find_partition "$partition" 2>/dev/null || true)
    if [ -z "$device" ]; then
        log_skip "$partition: partition label not present"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    FOUND_COUNT=$((FOUND_COUNT + 1))
    if [ ! -b "$device" ]; then
        log_fail "$partition: resolved path is not a block device: $device"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if dd if="$device" of=/dev/null bs=512 count=1 2>> "$ERROR_LOG"; then
        log_pass "$partition: one-sector read completed successfully from $device"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        log_fail "$partition: read failed for $device"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if [ "$FOUND_COUNT" -eq 0 ]; then
    if [ "$PARTITION_MODE" -eq 1 ]; then
        log_fail "$TESTNAME FAIL: rmtfs uses partition mode but no requested partition labels were present"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif rmtfs_process_running rmtfs && \
         [ "$PARTITION_MODE_KNOWN" -eq 1 ]; then
        log_skip "$TESTNAME SKIP: the running rmtfs daemon uses a directory-backed deployment"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    elif rmtfs_process_running rmtfs; then
        log_skip "$TESTNAME SKIP: the running rmtfs daemon storage mode could not be determined"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    elif [ "$RMTFS_DT_PRESENT" -eq 1 ]; then
        log_fail "$TESTNAME FAIL: RMTFS hardware is applicable but no daemon or partition storage became available"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        log_skip "$TESTNAME SKIP: no requested RMTFS partition labels were present"
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
fi

if rmtfs_runtime_cleanup; then
    log_pass "Initial RMTFS module and service state restored"
else
    log_fail "Unable to restore the initial RMTFS module or service state"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

log_info "Summary: found=$FOUND_COUNT pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi
if [ "$PASS_COUNT" -gt 0 ]; then
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi
echo "$TESTNAME SKIP" > "$RES_FILE"
exit 0
