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

TESTNAME="RMTFS_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

test_path=$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi
rm -f "$RES_FILE"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass_case() {
    log_pass "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_case() {
    log_fail "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip_case() {
    log_skip "$1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

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

OS_ID=$(pkg_detect_os_id 2>/dev/null || echo unknown)
detect_platform >/dev/null 2>&1 || true
log_info "Starting $TESTNAME on OS=$OS_ID platform=${PLATFORM_TARGET:-unknown}"
log_info "No package installation is attempted because all supported distributions use image-provided RMTFS components"

log_info "--- TC-00: kernel module and shared-memory runtime ---"
if [ "$RMTFS_LEGACY_APPLICABLE" -eq 1 ] && \
   [ "$RMTFS_MAINLINE_APPLICABLE" -eq 0 ]; then
    pass_case "TC-00: legacy RMTFS runtime evidence detected"
else
    if [ "$RMTFS_DT_PRESENT" -eq 1 ]; then
        pass_case "TC-00: qcom,rmtfs-mem is present in the runtime device tree"
    fi

    if [ "$RMTFS_MODULE_WAS_LOADED" -eq 1 ]; then
        pass_case "TC-00: rmtfs_mem was already loaded and will remain loaded"
    elif [ "$RMTFS_MODULE_LOADED_BY_TEST" -eq 1 ]; then
        pass_case "TC-00: rmtfs_mem was loaded temporarily for functional validation"
    elif [ "$RMTFS_MODULE_LOAD_ATTEMPTED" -eq 1 ] && \
         [ "$RMTFS_MODULE_LOAD_FAILED" -eq 1 ]; then
        fail_case "TC-00: the initially unloaded rmtfs_mem module could not be loaded"
    elif [ "$RMTFS_CONFIG_VALUE" = "y" ]; then
        pass_case "TC-00: CONFIG_QCOM_RMTFS_MEM=y, a separate module is not required"
    fi

    if [ -n "$RMTFS_MAINLINE_DEVICE" ]; then
        pass_case "TC-00: shared-memory character device found: $RMTFS_MAINLINE_DEVICE"
    elif [ -n "$RMTFS_UIO_DEVICE" ]; then
        pass_case "TC-00: RMTFS UIO shared-memory device found: $RMTFS_UIO_DEVICE"
    elif [ "$RMTFS_DT_PRESENT" -eq 1 ] && \
         [ -c /dev/mem ] && [ -r /dev/mem ] && [ -w /dev/mem ]; then
        pass_case "TC-00: reserved-memory /dev/mem fallback is available"
    elif rmtfs_process_running rmtfs; then
        pass_case "TC-00: the running rmtfs daemon has an initialized shared-memory backend"
    else
        fail_case "TC-00: no usable RMTFS shared-memory runtime appeared after module validation"
    fi
fi

if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 1 ]; then
    rmtfs_start_service_if_available || true
fi

log_info "--- TC-01: daemon/service health ---"
DAEMON_RUNNING=0
ACTIVE_UNIT=""
if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 1 ]; then
    ACTIVE_UNIT=$(rmtfs_get_active_service_unit 2>/dev/null || true)
    if rmtfs_process_running rmtfs; then
        DAEMON_RUNNING=1
    fi
fi
if [ "$RMTFS_LEGACY_APPLICABLE" -eq 1 ] && [ "$DAEMON_RUNNING" -eq 0 ]; then
    for unit in rmt_storage qcom-rmt-storage; do
        if systemd_service_exists "$unit" && systemd_service_is_active "$unit"; then
            ACTIVE_UNIT="$unit"
            DAEMON_RUNNING=1
            break
        fi
    done
    if rmtfs_process_running rmt_storage; then
        DAEMON_RUNNING=1
    fi
fi

if [ "$DAEMON_RUNNING" -eq 1 ]; then
    pass_case "TC-01: RMTFS daemon is running${ACTIVE_UNIT:+ via $ACTIVE_UNIT}"
else
    SYSV_FOUND=0
    for init_script in /etc/init.d/rmtfs /etc/init.d/rmt_storage; do
        if [ -x "$init_script" ]; then
            SYSV_FOUND=1
            if "$init_script" status >/dev/null 2>&1; then
                pass_case "TC-01: SysV RMTFS service is running: $init_script"
                DAEMON_RUNNING=1
            else
                fail_case "TC-01: SysV RMTFS service is not running: $init_script"
            fi
            break
        fi
    done
    if [ "$SYSV_FOUND" -ne 1 ]; then
        fail_case "TC-01: RMTFS hardware is present but no rmtfs/rmt_storage daemon is running"
    fi
fi

log_info "--- TC-02: daemon binary availability ---"
RMTFS_BIN=$(command -v rmtfs 2>/dev/null || true)
LEGACY_BIN=$(command -v rmt_storage 2>/dev/null || true)
if [ -z "$RMTFS_BIN" ]; then
    for candidate in \
        /usr/bin/rmtfs \
        /usr/sbin/rmtfs \
        /usr/local/bin/rmtfs \
        /sbin/rmtfs
    do
        if [ -x "$candidate" ]; then
            RMTFS_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$LEGACY_BIN" ]; then
    for candidate in \
        /usr/bin/rmt_storage \
        /usr/sbin/rmt_storage \
        /sbin/rmt_storage
    do
        if [ -x "$candidate" ]; then
            LEGACY_BIN="$candidate"
            break
        fi
    done
fi
if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 1 ] && [ -n "$RMTFS_BIN" ]; then
    pass_case "TC-02: mainline rmtfs binary found: $RMTFS_BIN"
elif [ "$RMTFS_LEGACY_APPLICABLE" -eq 1 ] && [ -n "$LEGACY_BIN" ]; then
    pass_case "TC-02: legacy rmt_storage binary found: $LEGACY_BIN"
else
    fail_case "TC-02: no binary matching the detected RMTFS implementation was found"
fi

log_info "--- TC-03: QMI transport availability ---"
if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 1 ]; then
    if [ -e /sys/bus/qrtr ] || [ -e /proc/net/qrtr ] || [ -e /sys/module/qrtr ] || \
       is_module_loaded qrtr || rmtfs_process_running rmtfs; then
        pass_case "TC-03: QRTR transport is available (QRTR does not require /dev/qrtr)"
    else
        fail_case "TC-03: mainline RMTFS detected but no QRTR transport evidence was found"
    fi
elif [ -e /dev/msm_ipc ]; then
    pass_case "TC-03: legacy IPC Router device found: /dev/msm_ipc"
else
    skip_case "TC-03: legacy transport interface could not be identified"
fi

log_info "--- TC-04: kernel log health ---"
RMTFS_DMESG_DIR="$SCRIPT_DIR/rmtfs_dmesg"
RMTFS_DMESG_MODULES='rmtfs|rmt_storage|qcom_rmtfs_mem|qcom-rmtfs-mem|rmtfs_mem|msm_sharedmem'
RMTFS_DMESG_EXCLUDE='optional|not supported|deferred probe'
RMTFS_DMESG_ERRORS_FOUND=0
RMTFS_DMESG_READABLE=0

if scan_dmesg_errors \
    "$RMTFS_DMESG_DIR" \
    "$RMTFS_DMESG_MODULES" \
    "$RMTFS_DMESG_EXCLUDE"; then
    RMTFS_DMESG_ERRORS_FOUND=1
fi
if [ -s "$RMTFS_DMESG_DIR/dmesg_snapshot.log" ]; then
    RMTFS_DMESG_READABLE=1
fi

if [ "$RMTFS_DMESG_READABLE" -eq 1 ]; then
    if [ "$RMTFS_DMESG_ERRORS_FOUND" -eq 1 ]; then
        fail_case "TC-04: RMTFS errors found in dmesg, see rmtfs_dmesg/dmesg_errors.log"
    else
        pass_case "TC-04: no relevant RMTFS errors found in dmesg"
    fi
else
    skip_case "TC-04: dmesg is not readable by the current test user"
fi

log_info "--- TC-05: state restoration ---"
if rmtfs_runtime_cleanup; then
    log_pass "TC-05: initial RMTFS module and service state restored"
else
    fail_case "TC-05: unable to restore the initial RMTFS module or service state"
fi

log_info "Summary: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
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
