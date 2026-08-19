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

TESTNAME="MinkIPC_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

test_path=$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)
if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi
rm -f "$RES_FILE"

if ! minkipc_prepare_test_packages; then
    log_fail "$TESTNAME FAIL: MinkIPC package preparation failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

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

process_running_quiet() {
    get_pid "$1" >/dev/null 2>&1
}

module_loaded_quiet() {
    is_module_loaded "$1" >/dev/null 2>&1
}

find_shared_library() {
    fsl_name="$1"
    fsl_path=""

    if command -v ldconfig >/dev/null 2>&1; then
        fsl_path=$(ldconfig -p 2>/dev/null | awk -v name="$fsl_name" '$1 ~ ("^" name "\\.so") { print $NF; exit }')
        if [ -n "$fsl_path" ] && [ -e "$fsl_path" ]; then
            printf '%s\n' "$fsl_path"
            return 0
        fi
    fi

    for fsl_path in \
        /lib/"$fsl_name".so* /usr/lib/"$fsl_name".so* \
        /lib64/"$fsl_name".so* /usr/lib64/"$fsl_name".so* \
        /lib/*-linux-gnu/"$fsl_name".so* \
        /usr/lib/*-linux-gnu/"$fsl_name".so*; do
        if [ -e "$fsl_path" ]; then
            printf '%s\n' "$fsl_path"
            return 0
        fi
    done

    return 1
}

find_binary() {
    fb_name="$1"
    fb_path=$(command -v "$fb_name" 2>/dev/null || true)
    if [ -n "$fb_path" ] && [ -x "$fb_path" ]; then
        printf '%s\n' "$fb_path"
        return 0
    fi

    for fb_path in /usr/bin/"$fb_name" /usr/sbin/"$fb_name" \
        /usr/local/bin/"$fb_name" /sbin/"$fb_name" /bin/"$fb_name" \
        /usr/libexec/"$fb_name" /usr/libexec/minkipc/"$fb_name"; do
        if [ -x "$fb_path" ]; then
            printf '%s\n' "$fb_path"
            return 0
        fi
    done

    return 1
}

path_is_mounted() {
    pim_path="$1"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n "$pim_path" >/dev/null 2>&1
        return $?
    fi
    awk -v path="$pim_path" '$2 == path { found=1 } END { exit !found }' /proc/self/mounts 2>/dev/null
}

MINK_LIB=$(find_shared_library libminkadaptor 2>/dev/null || true)
MINKTEEC_LIB=$(find_shared_library libminkteec 2>/dev/null || true)
LEGACY_DEV=""
MODERN_DEV=""
MODERN_EVIDENCE=""

if [ -e /dev/smcinvoke ]; then
    LEGACY_DEV=/dev/smcinvoke
fi

for candidate in /dev/qcomtee /dev/qcomtee0; do
    if [ -e "$candidate" ]; then
        MODERN_DEV="$candidate"
        MODERN_EVIDENCE="QCOMTEE-specific device node"
        break
    fi
done

if [ -z "$MODERN_DEV" ]; then
    for tee_sys in /sys/class/tee/tee[0-9]*; do
        [ -e "$tee_sys" ] || continue
        tee_name=$(basename "$tee_sys")
        tee_metadata=$(
            cat "$tee_sys/name" "$tee_sys/uevent" "$tee_sys/device/uevent" 2>/dev/null
            readlink -f "$tee_sys/device/driver" 2>/dev/null
        )
        if printf '%s\n' "$tee_metadata" | grep -qiE 'qcom|qualcomm|qtee'; then
            if [ -e "/dev/$tee_name" ]; then
                MODERN_DEV="/dev/$tee_name"
                MODERN_EVIDENCE="QCOMTEE sysfs metadata"
                break
            fi
        fi
    done
fi

if [ -z "$MODERN_DEV" ] && [ -e /dev/tee0 ] && [ -n "$MINK_LIB" ]; then
    if process_running_quiet qtee_supplicant || systemd_service_exists qteesupplicant; then
        MODERN_DEV=/dev/tee0
        MODERN_EVIDENCE="libminkadaptor and qteesupplicant"
    fi
fi

LEGACY_MODULE=0
MODERN_MODULE=0
for module in qcom_smcinvoke smcinvoke; do
    if module_loaded_quiet "$module"; then
        LEGACY_MODULE=1
        break
    fi
done
for module in qcomtee qcom_tee; do
    if module_loaded_quiet "$module"; then
        MODERN_MODULE=1
        break
    fi
done

MINKIPC_DMESG_DIR="$SCRIPT_DIR/minkipc_dmesg"
MINKIPC_DMESG_MODULES='qcomtee|qcom_tee|qcom-tee|qcom_smcinvoke|qcom-smcinvoke|smcinvoke|qtee'
MINKIPC_DMESG_EXCLUDE='optional|not supported|deferred probe'
MINKIPC_DMESG_ERRORS_FOUND=0
MINKIPC_DMESG_READABLE=0

if scan_dmesg_errors \
    "$MINKIPC_DMESG_DIR" \
    "$MINKIPC_DMESG_MODULES" \
    "$MINKIPC_DMESG_EXCLUDE"; then
    MINKIPC_DMESG_ERRORS_FOUND=1
fi
if [ -s "$MINKIPC_DMESG_DIR/dmesg_snapshot.log" ]; then
    MINKIPC_DMESG_READABLE=1
fi

DMESG_MARKER=0
if [ "$MINKIPC_DMESG_READABLE" -eq 1 ] && \
   grep -qiE 'qcomtee|qcom[_ -]?smcinvoke|smcinvoke' \
       "$MINKIPC_DMESG_DIR/dmesg_snapshot.log"; then
    DMESG_MARKER=1
fi

DT_MARKER=0
if dt_confirm_node_or_compatible_all "qcom,smcinvoke" "qcom,qtee" >/dev/null 2>&1; then
    DT_MARKER=1
fi

if [ -z "$MODERN_DEV" ] && [ -e /dev/tee0 ] && \
   { [ "$DMESG_MARKER" -eq 1 ] || [ "$DT_MARKER" -eq 1 ]; }; then
    MODERN_DEV=/dev/tee0
    MODERN_EVIDENCE="Qualcomm kernel/device-tree evidence"
fi

if [ -z "$LEGACY_DEV" ] && [ -z "$MODERN_DEV" ] && \
   [ "$LEGACY_MODULE" -eq 0 ] && [ "$MODERN_MODULE" -eq 0 ] && \
   [ "$DMESG_MARKER" -eq 0 ] && [ "$DT_MARKER" -eq 0 ]; then
    log_skip "$TESTNAME SKIP: no Qualcomm MinkIPC/QCOMTEE hardware interface detected"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

OS_ID=$(pkg_detect_os_id 2>/dev/null || printf '%s\n' unknown)
detect_platform >/dev/null 2>&1 || true

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "OS=$OS_ID platform=${PLATFORM_TARGET:-unknown} arch=$(uname -m 2>/dev/null || echo unknown)"
log_info "Debian and Ubuntu use the verified MinkIPC package set, other distributions use image-provided components"

log_info "--- TC-01: Qualcomm TEE driver interface ---"
if [ -n "$LEGACY_DEV" ]; then
    if [ -c "$LEGACY_DEV" ]; then
        pass_case "TC-01: legacy SMCInvoke character device found: $LEGACY_DEV"
    else
        fail_case "TC-01: legacy SMCInvoke path is not a character device: $LEGACY_DEV"
    fi
elif [ "$LEGACY_MODULE" -eq 1 ]; then
    fail_case "TC-01: legacy SMCInvoke module is loaded but /dev/smcinvoke is absent"
fi

if [ -n "$MODERN_DEV" ]; then
    if [ -c "$MODERN_DEV" ]; then
        pass_case "TC-01: QCOMTEE-backed device found: $MODERN_DEV ($MODERN_EVIDENCE)"
    else
        fail_case "TC-01: QCOMTEE path is not a character device: $MODERN_DEV"
    fi
elif [ "$MODERN_MODULE" -eq 1 ]; then
    fail_case "TC-01: QCOMTEE module is loaded but no QCOMTEE-backed TEE device was identified"
fi

if [ -z "$LEGACY_DEV" ] && [ -z "$MODERN_DEV" ] && \
   [ "$LEGACY_MODULE" -eq 0 ] && [ "$MODERN_MODULE" -eq 0 ]; then
    fail_case "TC-01: Qualcomm MinkIPC hardware evidence exists but no usable device interface was found"
fi

log_info "--- TC-02: architecture-neutral library discovery ---"
if [ -n "$MINK_LIB" ]; then
    pass_case "TC-02: libminkadaptor found: $MINK_LIB"
else
    fail_case "TC-02: libminkadaptor was not found through ldconfig or standard multiarch paths"
fi

if [ -n "$MINKTEEC_LIB" ]; then
    pass_case "TC-02: optional libminkteec found: $MINKTEEC_LIB"
else
    skip_case "TC-02: libminkteec is not installed, GP diagnostics are covered by MinkIPC_GPTEEC_Validation"
fi

log_info "--- TC-03: qtee_supplicant runtime health ---"
SUPPLICANT_BIN=$(find_binary qtee_supplicant 2>/dev/null || true)
SUPPLICANT_UNIT=""
for unit in qteesupplicant qtee-supplicant minkipc-qteesupplicant; do
    if systemd_service_exists "$unit"; then
        SUPPLICANT_UNIT="$unit"
        break
    fi
done

SUPPLICANT_RUNNING=0
for process in qtee_supplicant qteesupplicant; do
    if process_running_quiet "$process"; then
        SUPPLICANT_RUNNING=1
        break
    fi
done

if [ -n "$SUPPLICANT_UNIT" ]; then
    if systemd_service_is_active "$SUPPLICANT_UNIT" || [ "$SUPPLICANT_RUNNING" -eq 1 ]; then
        pass_case "TC-03: qtee_supplicant is active ($SUPPLICANT_UNIT)"
    else
        fail_case "TC-03: $SUPPLICANT_UNIT exists but qtee_supplicant is not running"
    fi
elif [ "$SUPPLICANT_RUNNING" -eq 1 ]; then
    pass_case "TC-03: qtee_supplicant process is running without a systemd unit"
else
    SYSV_FOUND=0
    for init_script in /etc/init.d/qtee_supplicant /etc/init.d/qteesupplicant; do
        if [ -x "$init_script" ]; then
            SYSV_FOUND=1
            if "$init_script" status >/dev/null 2>&1; then
                pass_case "TC-03: SysV qtee_supplicant service is running: $init_script"
            else
                fail_case "TC-03: SysV qtee_supplicant service is not running: $init_script"
            fi
            break
        fi
    done
    if [ "$SYSV_FOUND" -eq 0 ]; then
        if [ -n "$SUPPLICANT_BIN" ]; then
            fail_case "TC-03: qtee_supplicant binary exists but no running service/process was found: $SUPPLICANT_BIN"
        else
            skip_case "TC-03: qtee_supplicant is not provisioned on this platform"
        fi
    fi
fi

log_info "--- TC-04: secure-filesystem initialization and ordering ---"
SFS_UNIT=""
for unit in sfsconfig minkipc-sfsconfig sfs-config; do
    if systemd_service_exists "$unit"; then
        SFS_UNIT="$unit"
        break
    fi
done
SFS_BIN=$(find_binary sfs_config 2>/dev/null || find_binary sfsconfig 2>/dev/null || true)

if [ -n "$SFS_UNIT" ]; then
    SFS_ACTIVE=$(systemctl show "$SFS_UNIT" -p ActiveState --value 2>/dev/null || true)
    SFS_RESULT=$(systemctl show "$SFS_UNIT" -p Result --value 2>/dev/null || true)
    SFS_STATUS=$(systemctl show "$SFS_UNIT" -p ExecMainStatus --value 2>/dev/null || true)
    if [ "$SFS_ACTIVE" = "active" ] || { [ "$SFS_RESULT" = "success" ] && [ "${SFS_STATUS:-0}" = "0" ]; }; then
        pass_case "TC-04: one-shot SFS configuration completed successfully: $SFS_UNIT"
    else
        fail_case "TC-04: SFS configuration did not complete successfully: active=$SFS_ACTIVE result=$SFS_RESULT status=$SFS_STATUS"
    fi

    if path_is_mounted /var/lib/tee; then
        SFS_AFTER=$(systemctl show "$SFS_UNIT" -p After --value 2>/dev/null || true)
        SFS_UNIT_TEXT=$(systemctl cat "$SFS_UNIT" 2>/dev/null || true)
        if printf '%s\n%s\n' "$SFS_AFTER" "$SFS_UNIT_TEXT" | grep -qiE 'var-lib-tee\.mount|persist[^ ]*\.mount'; then
            pass_case "TC-04: SFS service is ordered after persistent TEE storage"
        else
            fail_case "TC-04: /var/lib/tee is mounted but $SFS_UNIT has no persistent-mount ordering"
        fi
    else
        skip_case "TC-04: /var/lib/tee is not a separate mounted persistence path, so mount ordering is not applicable"
    fi

    for sfs_dir in /var/lib/tee/qtee_supplicant /var/lib/qtee_supplicant/vendor/tzstorage; do
        if [ -d "$sfs_dir" ]; then
            pass_case "TC-04: secure-filesystem directory exists: $sfs_dir"
        else
            fail_case "TC-04: expected secure-filesystem directory is missing: $sfs_dir"
        fi
    done
elif [ -n "$SFS_BIN" ]; then
    skip_case "TC-04: SFS helper exists without systemd, so ordering cannot be verified portably: $SFS_BIN"
else
    skip_case "TC-04: SFS configuration is not provisioned on this platform"
fi

log_info "--- TC-05: device accessibility ---"
ACCESS_DEV=${MODERN_DEV:-$LEGACY_DEV}
if [ -n "$ACCESS_DEV" ]; then
    if [ -r "$ACCESS_DEV" ] && [ -w "$ACCESS_DEV" ]; then
        pass_case "TC-05: current test user can read and write $ACCESS_DEV"
    else
        fail_case "TC-05: current test user cannot read and write $ACCESS_DEV"
    fi
else
    skip_case "TC-05: no device node available for permission validation"
fi

log_info "--- TC-06: kernel log health ---"
if [ "$MINKIPC_DMESG_READABLE" -eq 1 ]; then
    if [ "$MINKIPC_DMESG_ERRORS_FOUND" -eq 1 ]; then
        fail_case "TC-06: MinkIPC/QCOMTEE errors found in dmesg, see minkipc_dmesg/dmesg_errors.log"
    else
        pass_case "TC-06: no relevant MinkIPC/QCOMTEE errors found in dmesg"
    fi
else
    skip_case "TC-06: dmesg is not readable by the current test user"
fi

log_info "Summary: pass=$PASS_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    log_fail "$TESTNAME FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi
if [ "$PASS_COUNT" -gt 0 ]; then
    log_pass "$TESTNAME PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi

log_skip "$TESTNAME SKIP"
echo "$TESTNAME SKIP" > "$RES_FILE"
exit 0
