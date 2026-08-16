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

TESTNAME="RMTFS_Shared_Memory_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
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
    log_skip "$TESTNAME SKIP: no RMTFS shared-memory implementation detected"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

if [ "$PREPARE_RC" -ne 0 ]; then
    log_fail "$TESTNAME FAIL: unable to prepare the RMTFS runtime snapshot"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

OS_ID=$(pkg_detect_os_id 2>/dev/null || echo unknown)
log_info "Starting $TESTNAME on OS=$OS_ID"

log_info "--- TC-01: kernel configuration/module ---"
case "$RMTFS_CONFIG_VALUE" in
    y)
        pass_case "TC-01: CONFIG_QCOM_RMTFS_MEM=y"
        ;;
    m)
        pass_case "TC-01: CONFIG_QCOM_RMTFS_MEM=m"
        if [ -n "$RMTFS_MODULE_PATH" ]; then
            pass_case "TC-01: rmtfs_mem module file is present: $RMTFS_MODULE_PATH"
        elif [ "$RMTFS_MODULE_WAS_LOADED" -eq 1 ]; then
            pass_case "TC-01: rmtfs_mem was already loaded when the test started"
        else
            skip_case "TC-01: module file is not visible, fallback shared-memory paths will be checked"
        fi
        ;;
    n)
        if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 1 ]; then
            fail_case "TC-01: RMTFS hardware is present but CONFIG_QCOM_RMTFS_MEM is disabled"
        else
            skip_case "TC-01: CONFIG_QCOM_RMTFS_MEM is not required by the legacy stack"
        fi
        ;;
    *)
        if [ "$RMTFS_LEGACY_APPLICABLE" -eq 1 ]; then
            skip_case "TC-01: CONFIG_QCOM_RMTFS_MEM is not required by the legacy stack"
        else
            skip_case "TC-01: running-kernel configuration is unavailable"
        fi
        ;;
esac

if [ "$RMTFS_MODULE_WAS_LOADED" -eq 1 ]; then
    pass_case "TC-01: initially loaded rmtfs_mem module will not be removed"
elif [ "$RMTFS_MODULE_LOADED_BY_TEST" -eq 1 ]; then
    pass_case "TC-01: rmtfs_mem loaded temporarily for this validation"
elif [ "$RMTFS_MODULE_LOAD_ATTEMPTED" -eq 1 ] && \
     [ "$RMTFS_MODULE_LOAD_FAILED" -eq 1 ]; then
    fail_case "TC-01: the initially unloaded rmtfs_mem module could not be loaded"
elif [ "$RMTFS_CONFIG_VALUE" = "y" ]; then
    pass_case "TC-01: RMTFS memory driver is built into the kernel"
else
    skip_case "TC-01: no active rmtfs_mem module, checking supported fallbacks"
fi

log_info "--- TC-02: mainline qcom_rmtfs_mem device ---"
MAINLINE_DEVICE_FOUND=0
for dev in /dev/qcom_rmtfs_mem*; do
    if [ ! -e "$dev" ]; then
        continue
    fi
    MAINLINE_DEVICE_FOUND=1
    if [ -c "$dev" ] && [ -r "$dev" ] && [ -w "$dev" ]; then
        pass_case "TC-02: shared-memory character device is accessible: $dev"
    else
        fail_case "TC-02: shared-memory device is not an accessible character device: $dev"
    fi

    dev_name=$(basename "$dev")
    sys_path="/sys/class/rmtfs/$dev_name"
    if [ ! -d "$sys_path" ] && command -v udevadm >/dev/null 2>&1; then
        udev_path=$(udevadm info -q path -n "$dev" 2>/dev/null || true)
        if [ -n "$udev_path" ]; then
            sys_path="/sys$udev_path"
        fi
    fi
    if [ -r "$sys_path/phys_addr" ] && [ -r "$sys_path/size" ]; then
        pass_case "TC-02: phys_addr and size sysfs attributes are present for $dev_name"
    else
        fail_case "TC-02: phys_addr/size sysfs attributes are missing for $dev_name"
    fi
done
if [ "$RMTFS_MAINLINE_APPLICABLE" -eq 1 ] && [ "$MAINLINE_DEVICE_FOUND" -eq 0 ]; then
    skip_case "TC-02: no qcom_rmtfs_mem device, checking supported UIO or /dev/mem fallback"
fi

log_info "--- TC-03: UIO shared-memory fallback ---"
UIO_FOUND=0
for uio_name in /sys/class/uio/uio*/name; do
    if [ ! -r "$uio_name" ]; then
        continue
    fi
    if ! grep -qi '^rmtfs$' "$uio_name"; then
        continue
    fi
    UIO_FOUND=1
    uio_dir=$(dirname "$uio_name")
    uio_node="/dev/$(basename "$uio_dir")"
    if [ -c "$uio_node" ] && [ -r "$uio_dir/maps/map0/addr" ] && [ -r "$uio_dir/maps/map0/size" ]; then
        pass_case "TC-03: legacy RMTFS UIO device and map0 metadata are present: $uio_node"
    else
        fail_case "TC-03: RMTFS UIO mapping is incomplete: $uio_dir"
    fi
done
for dev in /dev/qcom_rmtfs_uio*; do
    if [ ! -e "$dev" ]; then
        continue
    fi
    UIO_FOUND=1
    if [ -c "$dev" ] && [ -r "$dev" ] && [ -w "$dev" ]; then
        pass_case "TC-03: qcom_rmtfs_uio compatibility device is accessible: $dev"
    else
        fail_case "TC-03: qcom_rmtfs_uio device is not accessible: $dev"
    fi
done
if [ "$UIO_FOUND" -eq 0 ]; then
    skip_case "TC-03: UIO fallback is not used on this platform"
fi

log_info "--- TC-04: reserved-memory /dev/mem fallback ---"
if [ "$MAINLINE_DEVICE_FOUND" -eq 0 ] && [ "$UIO_FOUND" -eq 0 ]; then
    if [ "$RMTFS_DT_PRESENT" -eq 1 ] && \
       [ -c /dev/mem ] && [ -r /dev/mem ] && [ -w /dev/mem ]; then
        pass_case "TC-04: reserved-memory and /dev/mem fallback are available"
    elif [ "$RMTFS_LEGACY_APPLICABLE" -eq 1 ]; then
        skip_case "TC-04: legacy RMTFS does not expose a mainline shared-memory device"
    else
        fail_case "TC-04: no usable mainline, UIO, or /dev/mem RMTFS shared-memory path was found"
    fi
else
    skip_case "TC-04: /dev/mem fallback is not needed"
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
