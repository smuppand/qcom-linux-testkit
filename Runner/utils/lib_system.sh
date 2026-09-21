#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Common helpers for System/Yocto userspace validation tests.
#
# This library intentionally keeps framework-level helpers in functestlib.sh
# and provides System-suite specific helpers here. Current users include
# EFI_Variable_Validation.

# ---------------------------------------------------------------------------
# Default EFI constants
# ---------------------------------------------------------------------------

: "${EFI_GLOBAL_GUID:=8be4df61-93ca-11d2-aa0d-00e098032b8c}"
: "${OS_TRIAL_BOOT_STATUS_VAR:=${EFI_GLOBAL_GUID}-OsTrialBootStatus}"
: "${OS_INDICATIONS_SUPPORTED_VAR:=${EFI_GLOBAL_GUID}-OsIndicationsSupported}"
: "${EFIVARFS_PATH:=/sys/firmware/efi/efivars}"
: "${EFIVARFS_RESTORE_RO:=0}"

# ---------------------------------------------------------------------------
# Generic System-suite result helpers
# ---------------------------------------------------------------------------

# Return the active result file path.
# Prefer RES_FILE from the testcase; fallback to TESTNAME.res when available.
system_result_file() {
    if [ -n "${RES_FILE:-}" ]; then
        printf '%s\n' "$RES_FILE"
        return 0
    fi

    if [ -n "${TESTNAME:-}" ]; then
        printf './%s.res\n' "$TESTNAME"
        return 0
    fi

    printf './UnknownTest.res\n'
    return 0
}

# Write the final testcase result and exit cleanly.
# This keeps PASS/FAIL/SKIP exits consistent across System-suite tests.
system_write_result_and_exit() {
    result="$1"
    message="$2"
    result_file="$(system_result_file)"

    case "$result" in
        PASS)
            log_pass "$message"
            ;;
        FAIL)
            log_fail "$message"
            ;;
        SKIP)
            log_skip "$message"
            ;;
        *)
            log_fail "${TESTNAME:-UnknownTest}, invalid result requested: $result"
            result="FAIL"
            ;;
    esac

    echo "${TESTNAME:-UnknownTest} $result" > "$result_file"
    exit 0
}

# Complete the test as PASS with the common completion log.
# Used when mandatory validation passed and only optional platform-specific
# checks are unavailable.
system_finish_pass() {
    message="$1"
    result_file="$(system_result_file)"

    log_pass "$message"
    echo "${TESTNAME:-UnknownTest} PASS" > "$result_file"

    if [ -n "${TESTNAME:-}" ]; then
        log_info "------------------- Completed ${TESTNAME} Testcase ----------------------------"
    fi

    exit 0
}

# ---------------------------------------------------------------------------
# Generic System-suite log helpers
# ---------------------------------------------------------------------------

# Return success when the given value is an unsigned integer.
system_is_uint() {
    case "$1" in
        ""|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Log the first N lines from a file with a stable prefix.
# Usage:
# system_log_file_excerpt "efivar-list" "./efi_vars.list" 40
system_log_file_excerpt() {
    log_prefix="$1"
    log_file="$2"
    log_lines="${3:-40}"

    if ! system_is_uint "$log_lines"; then
        log_lines=40
    fi

    if [ ! -f "$log_file" ]; then
        log_warn "Log file not found for excerpt: $log_file"
        return 1
    fi

    sed -n "1,${log_lines}p" "$log_file" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        log_info "[${log_prefix}] $line"
    done

    return 0
}

# Require a fixed string to be present in a file.
system_require_grep_in_file() {
    pattern="$1"
    file_path="$2"
    fail_msg="$3"

    if grep -Fq "$pattern" "$file_path"; then
        return 0
    fi

    log_fail "$fail_msg"
    return 1
}

# system_select_rtc_device [requested-device]
# Selects a usable RTC character device from an optional absolute /dev path.
# Prints exactly one resolved device path on success and no diagnostics.
# Returns 0 when a readable and writable wakealarm is found, 1 when no device
# is eligible, and has no side effects. An explicitly disabled wakeup state is
# rejected, while an unavailable state remains eligible because some RTC
# drivers do not expose device/power/wakeup.
system_select_rtc_device() {
    ssrd_requested="${1:-}"

    if [ -n "$ssrd_requested" ]; then
        [ -c "$ssrd_requested" ] || return 1
        ssrd_resolved=$(readlink -f "$ssrd_requested") || return 1
        ssrd_name=${ssrd_resolved##*/}
        ssrd_alarm="/sys/class/rtc/$ssrd_name/wakealarm"
        ssrd_wakeup=$(cat "/sys/class/rtc/$ssrd_name/device/power/wakeup" 2>/dev/null || true)
        [ -r "$ssrd_alarm" ] && [ -w "$ssrd_alarm" ] || return 1
        [ "$ssrd_wakeup" != "disabled" ] || return 1
        printf '%s\n' "$ssrd_resolved"
        return 0
    fi

    for ssrd_device in /dev/rtc[0-9]*; do
        [ -c "$ssrd_device" ] || continue
        ssrd_name=${ssrd_device##*/}
        ssrd_alarm="/sys/class/rtc/$ssrd_name/wakealarm"
        ssrd_wakeup=$(cat "/sys/class/rtc/$ssrd_name/device/power/wakeup" 2>/dev/null || true)
        if [ -r "$ssrd_alarm" ] &&
           [ -w "$ssrd_alarm" ] &&
           [ "$ssrd_wakeup" != "disabled" ]; then
            printf '%s\n' "$ssrd_device"
            return 0
        fi
    done

    return 1
}

# system_capture_rtc_inventory <output-file> [requested-device]
# Records every RTC candidate and its wakealarm eligibility in a TSV file.
# The output path is required and the optional requested device is an absolute
# /dev path. Produces no stdout, returns 0 on capture, 1 on file failure, or 3
# for invalid arguments, and only creates or replaces the requested artifact.
system_capture_rtc_inventory() {
    scri_output_file="$1"
    scri_requested="${2:-}"

    [ -n "$scri_output_file" ] || return 3
    : >"$scri_output_file" || return 1
    printf 'device\tcharacter\twakealarm\treadable\twritable\twakeup\tselection\treason\n' >"$scri_output_file"

    for scri_device in /dev/rtc[0-9]*; do
        [ -e "$scri_device" ] || continue
        scri_name=${scri_device##*/}
        scri_alarm="/sys/class/rtc/$scri_name/wakealarm"
        scri_character=0
        scri_alarm_present=0
        scri_readable=0
        scri_writable=0
        scri_wakeup=$(cat "/sys/class/rtc/$scri_name/device/power/wakeup" 2>/dev/null || true)
        scri_selection="candidate"
        scri_reason="eligible"
        [ -c "$scri_device" ] && scri_character=1
        [ -e "$scri_alarm" ] && scri_alarm_present=1
        [ -r "$scri_alarm" ] && scri_readable=1
        [ -w "$scri_alarm" ] && scri_writable=1
        if [ -n "$scri_requested" ]; then
            if [ "$(readlink -f "$scri_device" 2>/dev/null || true)" = \
                 "$(readlink -f "$scri_requested" 2>/dev/null || true)" ]; then
                scri_selection="requested"
            else
                scri_selection="not-requested"
            fi
        fi
        if [ "$scri_character" -ne 1 ]; then
            scri_reason="not-character-device"
        elif [ "$scri_alarm_present" -ne 1 ]; then
            scri_reason="wakealarm-absent"
        elif [ "$scri_readable" -ne 1 ] || [ "$scri_writable" -ne 1 ]; then
            scri_reason="wakealarm-not-read-write"
        elif [ "$scri_wakeup" = "disabled" ]; then
            scri_reason="device-wakeup-disabled"
        elif [ -z "$scri_wakeup" ]; then
            scri_reason="eligible-wakeup-unreported"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$scri_device" \
            "$scri_character" \
            "$scri_alarm_present" \
            "$scri_readable" \
            "$scri_writable" \
            "${scri_wakeup:-unavailable}" \
            "$scri_selection" \
            "$scri_reason" >>"$scri_output_file"
    done
}

# system_log_rtc_inventory <inventory-file> [max-devices]
# Replays a bounded RTC inventory through log_info with named fields.
# The TSV path is required and max-devices is an optional unsigned count.
# Produces logs but no machine-readable stdout, returns 0 on success or 1 for
# unreadable input, and does not modify the inventory.
system_log_rtc_inventory() {
    slri_inventory_file="$1"
    slri_max_devices="${2:-16}"
    slri_total=0
    slri_emitted=0

    [ -r "$slri_inventory_file" ] || return 1
    case "$slri_max_devices" in
        ''|*[!0-9]*)
            return 3
            ;;
    esac
    slri_total=$(awk 'NR > 1 { count++ } END { print count + 0 }' "$slri_inventory_file")
    while IFS="$(printf '\t')" read -r slri_device slri_character slri_alarm slri_readable slri_writable slri_wakeup slri_selection slri_reason; do
        [ "$slri_device" = "device" ] && continue
        if [ "$slri_emitted" -ge "$slri_max_devices" ]; then
            break
        fi
        log_info "[SUSPEND-RTC-CANDIDATE] device=$slri_device character=$slri_character wakealarm=$slri_alarm readable=$slri_readable writable=$slri_writable wakeup=$slri_wakeup selection=$slri_selection reason=$slri_reason"
        slri_emitted=$((slri_emitted + 1))
    done <"$slri_inventory_file"
    if [ "$slri_total" -gt "$slri_emitted" ]; then
        log_info "[SUSPEND-RTC-CANDIDATE] omitted=$((slri_total - slri_emitted)) total=$slri_total artifact=$slri_inventory_file"
    fi
}

# system_arm_rtc_alarm <wakealarm-path> <seconds> <log-file>
# Arms and verifies a relative one-shot alarm through the RTC sysfs ABI.
# Inputs are a readable and writable wakealarm path, a positive integer number
# of seconds, and an artifact path. Produces no stdout, returns 0 on verified
# arm, 1 on access or verification failure, or 3 for invalid arguments, and
# changes the selected RTC alarm while retaining operation evidence.
system_arm_rtc_alarm() {
    sara_wakealarm_path="$1"
    sara_seconds="$2"
    sara_log_file="$3"

    [ -w "$sara_wakealarm_path" ] && [ -r "$sara_wakealarm_path" ] || return 1
    case "$sara_seconds" in
        ''|*[!0-9]*|0)
            return 3
            ;;
    esac
    [ -n "$sara_log_file" ] || return 3

    : >"$sara_log_file" || return 1
    if ! printf '0\n' >"$sara_wakealarm_path" 2>>"$sara_log_file"; then
        printf 'phase=clear status=failed\n' >>"$sara_log_file"
        return 1
    fi
    if ! printf '+%s\n' "$sara_seconds" >"$sara_wakealarm_path" 2>>"$sara_log_file"; then
        printf 'phase=arm requested_seconds=%s status=failed\n' \
            "$sara_seconds" >>"$sara_log_file"
        return 1
    fi
    if ! sara_observed=$(cat "$sara_wakealarm_path" 2>>"$sara_log_file"); then
        printf 'phase=verify requested_seconds=%s status=read-failed\n' \
            "$sara_seconds" >>"$sara_log_file"
        return 1
    fi
    printf 'phase=verify requested_seconds=%s observed_alarm=%s\n' \
        "$sara_seconds" \
        "${sara_observed:-empty}" >>"$sara_log_file"
    case "$sara_observed" in
        ''|0|*[!0-9]*)
            return 1
            ;;
    esac
    return 0
}

# system_clear_rtc_alarm <wakealarm-path> <log-file>
# Clears and verifies a test-owned RTC wake alarm.
# Inputs are the wakealarm path and an artifact path. Produces no stdout,
# returns 0 when the alarm reads empty or zero and 1 on failure, changes only
# the selected RTC alarm, and retains write diagnostics.
system_clear_rtc_alarm() {
    scra_wakealarm_path="$1"
    scra_log_file="$2"

    [ -r "$scra_wakealarm_path" ] &&
        [ -w "$scra_wakealarm_path" ] &&
        [ -n "$scra_log_file" ] || return 1

    if ! printf '0\n' >"$scra_wakealarm_path" 2>"$scra_log_file"; then
        return 1
    fi

    if ! scra_observed=$(cat "$scra_wakealarm_path" 2>>"$scra_log_file"); then
        printf 'phase=verify status=read-failed\n' >>"$scra_log_file"
        return 1
    fi
    [ -z "$scra_observed" ] || [ "$scra_observed" = "0" ]
}

# system_capture_bound_devices <output-file>
# Captures stable device, driver, and firmware-node tuples across common buses.
# The output path is required. Produces no stdout, returns 0 on success, 1 on
# file failure, or 3 for invalid arguments, and creates a sorted TSV snapshot
# without changing device state.
system_capture_bound_devices() {
    scbd_output_file="$1"

    [ -n "$scbd_output_file" ] || return 3
    : >"$scbd_output_file" || return 1

    for scbd_bus in platform pci i2c spi auxiliary usb mmc amba; do
        [ -d "/sys/bus/$scbd_bus/devices" ] || continue
        for scbd_device in "/sys/bus/$scbd_bus/devices"/*; do
            [ -e "$scbd_device" ] || continue
            [ -L "$scbd_device/driver" ] || continue
            scbd_driver=$(basename "$(readlink -f "$scbd_device/driver")")
            scbd_of_node=""
            if [ -L "$scbd_device/of_node" ]; then
                scbd_of_node=$(readlink -f "$scbd_device/of_node")
            fi
            printf '%s\t%s\t%s\t%s\n' \
                "$scbd_bus" \
                "${scbd_device##*/}" \
                "$scbd_driver" \
                "${scbd_of_node:-none}" >>"$scbd_output_file"
        done
    done

    sort -u "$scbd_output_file" -o "$scbd_output_file"
}

# system_capture_remoteproc_states <output-file>
# Captures remote processor name, firmware, and runtime state.
# The output path is required. Produces no stdout, returns 0 on success, 1 on
# file failure, or 3 for invalid arguments, and creates a sorted TSV snapshot
# without changing remote processor state.
system_capture_remoteproc_states() {
    scrs_output_file="$1"

    [ -n "$scrs_output_file" ] || return 3
    : >"$scrs_output_file" || return 1

    for scrs_remoteproc in /sys/class/remoteproc/remoteproc*; do
        [ -d "$scrs_remoteproc" ] || continue
        scrs_name=$(cat "$scrs_remoteproc/name" 2>/dev/null || true)
        scrs_firmware=$(cat "$scrs_remoteproc/firmware" 2>/dev/null || true)
        scrs_state=$(cat "$scrs_remoteproc/state" 2>/dev/null || true)
        printf '%s\tname=%s\tfirmware=%s\tstate=%s\n' \
            "${scrs_remoteproc##*/}" \
            "${scrs_name:-unknown}" \
            "${scrs_firmware:-unknown}" \
            "${scrs_state:-unknown}" >>"$scrs_output_file"
    done

    sort -u "$scrs_output_file" -o "$scrs_output_file"
}

# system_compare_snapshot_records <before-file> <after-file> <missing-file>
# Reports exact pre-operation records that are absent from a later snapshot.
# Inputs are two readable line-oriented files and an output artifact path.
# Produces no stdout, returns 0 when every record remains, 1 when records are
# missing, or 3 for unreadable input, and replaces the missing-record artifact.
system_compare_snapshot_records() {
    scsr_before_file="$1"
    scsr_after_file="$2"
    scsr_missing_file="$3"

    [ -r "$scsr_before_file" ] && [ -r "$scsr_after_file" ] || return 3

    awk '
        NR == FNR {
            after[$0]=1
            next
        }
        !($0 in after) {
            print
            missing=1
        }
        END {
            exit missing
        }
    ' "$scsr_after_file" "$scsr_before_file" >"$scsr_missing_file"
}

# system_wait_for_bound_devices <before-file> <after-file> <missing-file> <timeout>
# Polls until all pre-suspend bindings return or the bounded timeout expires.
# Inputs are the baseline, refreshed snapshot, missing-record artifact, and an
# unsigned timeout in seconds. Produces no stdout, returns 0 on recovery, 1 on
# capture failure or timeout, or 3 for invalid input, and refreshes artifacts.
system_wait_for_bound_devices() {
    swbd_before_file="$1"
    swbd_after_file="$2"
    swbd_missing_file="$3"
    swbd_timeout="$4"
    swbd_elapsed=0

    [ -r "$swbd_before_file" ] || return 3
    case "$swbd_timeout" in
        ''|*[!0-9]*)
            return 3
            ;;
    esac

    while [ "$swbd_elapsed" -le "$swbd_timeout" ]; do
        system_capture_bound_devices "$swbd_after_file" || return 1
        if system_compare_snapshot_records \
            "$swbd_before_file" \
            "$swbd_after_file" \
            "$swbd_missing_file"; then
            return 0
        fi
        if [ "$swbd_elapsed" -eq "$swbd_timeout" ]; then
            break
        fi
        sleep 1
        swbd_elapsed=$((swbd_elapsed + 1))
    done

    return 1
}

# system_wait_for_remoteproc_states <before-file> <after-file> <changed-file> <timeout>
# Polls until all pre-suspend remoteproc records return or timeout expires.
# Inputs are the baseline, refreshed snapshot, changed-record artifact, and an
# unsigned timeout in seconds. Produces no stdout, returns 0 on recovery, 1 on
# capture failure or timeout, or 3 for invalid input, and refreshes artifacts.
system_wait_for_remoteproc_states() {
    swrs_before_file="$1"
    swrs_after_file="$2"
    swrs_changed_file="$3"
    swrs_timeout="$4"
    swrs_elapsed=0

    [ -r "$swrs_before_file" ] || return 3
    case "$swrs_timeout" in
        ''|*[!0-9]*)
            return 3
            ;;
    esac

    while [ "$swrs_elapsed" -le "$swrs_timeout" ]; do
        system_capture_remoteproc_states "$swrs_after_file" || return 1
        if system_compare_snapshot_records \
            "$swrs_before_file" \
            "$swrs_after_file" \
            "$swrs_changed_file"; then
            return 0
        fi
        if [ "$swrs_elapsed" -eq "$swrs_timeout" ]; then
            break
        fi
        sleep 1
        swrs_elapsed=$((swrs_elapsed + 1))
    done

    return 1
}

# system_capture_wakeup_sources <output-file>
# Captures the best available read-only wake-source evidence.
# The output path is required. Produces no stdout, returns 0 when evidence is
# available, 1 when none can be read, or 3 for invalid arguments, and creates
# or replaces the requested artifact without changing wake-source state.
system_capture_wakeup_sources() {
    scws_output_file="$1"

    [ -n "$scws_output_file" ] || return 3
    : >"$scws_output_file" || return 1

    if [ -r /sys/kernel/debug/wakeup_sources ]; then
        cat /sys/kernel/debug/wakeup_sources >"$scws_output_file"
        return 0
    fi

    for scws_wakeup in /sys/class/wakeup/wakeup*; do
        [ -d "$scws_wakeup" ] || continue
        scws_name=$(cat "$scws_wakeup/name" 2>/dev/null || true)
        scws_active=$(cat "$scws_wakeup/active_count" 2>/dev/null || true)
        scws_events=$(cat "$scws_wakeup/event_count" 2>/dev/null || true)
        scws_wakeup_count=$(cat "$scws_wakeup/wakeup_count" 2>/dev/null || true)
        printf '%s\tname=%s\tactive_count=%s\tevent_count=%s\twakeup_count=%s\n' \
            "${scws_wakeup##*/}" \
            "${scws_name:-unknown}" \
            "${scws_active:-unknown}" \
            "${scws_events:-unknown}" \
            "${scws_wakeup_count:-unknown}" >>"$scws_output_file"
    done

    [ -s "$scws_output_file" ]
}

# ---------------------------------------------------------------------------
# EFI variable validation helpers
# ---------------------------------------------------------------------------

# Prepare OsTrialBootStatus payload.
# Expected payload:
# 01 77 01 00 00 00 00 00
#
# Caller must define:
# EFI_DATA_FILE
efi_write_trial_boot_status_payload() {
    if [ -z "${EFI_DATA_FILE:-}" ]; then
        log_fail "EFI_DATA_FILE is not set"
        return 1
    fi

    : > "$EFI_DATA_FILE" || return 1
    printf '\001\167\001\000\000\000\000\000' > "$EFI_DATA_FILE" || return 1

    return 0
}

# Require OsTrialBootStatus payload bytes in efivar print output.
efi_require_trial_boot_status_payload() {
    file_path="$1"
    expected_desc="$2"

    if grep -Eq '01[[:space:]]+77[[:space:]]+01[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00' "$file_path"; then
        return 0
    fi

    log_fail "EFI variable payload does not match expected value, required ${expected_desc}"
    return 1
}

# Require OsIndicationsSupported expected value.
# Current expected value:
# 04 00 00 00 00 00 00 00
#
# This helper returns failure but does not write testcase result. Callers can
# decide whether a mismatch is fatal or only a warning.
efi_require_os_indications_supported_value() {
    file_path="$1"

    if grep -Eq '04[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00[[:space:]]+00' "$file_path"; then
        return 0
    fi

    log_fail "OsIndicationsSupported value does not match expected value, required 04 00 00 00 00 00 00 00"
    return 1
}

# Detect efivar command failures that indicate firmware/runtime EFI variable
# services are not implemented or not supported on this platform.
efi_error_is_unsupported() {
    log_file="$1"

    grep -Eiq \
        'Function not implemented|Operation not supported|not supported|Invalid argument' \
        "$log_file"
}

# Detect efivar write failures that indicate the platform exposes EFI variables
# in read-only or write-restricted mode.
efi_error_is_write_restricted() {
    log_file="$1"

    grep -Eiq \
        'Read-only file system|Permission denied|Operation not permitted|write protected' \
        "$log_file"
}

# Check whether efivarfs is currently mounted.
# Prefer partition_mount_exists from functestlib.sh when available, with a
# /proc/mounts fallback.
efi_mount_exists() {
    if command -v partition_mount_exists >/dev/null 2>&1; then
        partition_mount_exists "$EFIVARFS_PATH"
        return $?
    fi

    awk -v p="$EFIVARFS_PATH" '
        $2 == p { found=1; exit }
        END { exit(found ? 0 : 1) }
    ' /proc/mounts 2>/dev/null
}

# Return efivarfs mount options.
# Prefer partition_get_mount_options from functestlib.sh when available.
efi_mount_options() {
    opts=""

    if command -v partition_get_mount_options >/dev/null 2>&1; then
        opts="$(partition_get_mount_options "$EFIVARFS_PATH" 2>/dev/null || true)"
    fi

    if [ -z "$opts" ]; then
        opts="$(
            awk -v p="$EFIVARFS_PATH" '$2 == p { print $4; exit }' /proc/mounts 2>/dev/null
        )"
    fi

    printf '%s\n' "$opts"
}

# Check whether efivarfs is mounted read-write.
efi_mount_is_rw() {
    opts="$(efi_mount_options)"

    printf '%s\n' "$opts" | grep -Eq '(^|,)rw(,|$)'
}

# Restore efivarfs to read-only when this test temporarily remounted it
# read-write. This prevents leaving the target in a different mount state.
efi_restore_efivarfs_ro() {
    if [ "$EFIVARFS_RESTORE_RO" != "1" ]; then
        return 0
    fi

    log_info "Restoring efivarfs mount to read-only"

    if mount -o remount,ro "$EFIVARFS_PATH" >/dev/null 2>&1; then
        log_info "efivarfs restored to read-only"
        EFIVARFS_RESTORE_RO=0
        return 0
    fi

    if mount -t efivarfs -o remount,ro efivarfs "$EFIVARFS_PATH" >/dev/null 2>&1; then
        log_info "efivarfs restored to read-only"
        EFIVARFS_RESTORE_RO=0
        return 0
    fi

    log_warn "Could not restore efivarfs to read-only"
    return 1
}

# Install cleanup trap for efivarfs remount restore.
# Call this from EFI tests before attempting temporary remount,rw.
efi_install_restore_trap() {
    trap efi_restore_efivarfs_ro EXIT HUP INT TERM
}

# Try to temporarily remount efivarfs read-write.
#
# Return 0 only if efivarfs becomes read-write.
# If this function changes efivarfs from ro to rw, it sets EFIVARFS_RESTORE_RO=1
# so efi_restore_efivarfs_ro can restore the original read-only state.
#
# Caller may define:
# EFI_REMOUNT_LOG
efi_try_remount_rw() {
    remount_log="${EFI_REMOUNT_LOG:-./efi_efivarfs_remount.log}"

    : > "$remount_log" 2>/dev/null || true

    if efi_mount_is_rw; then
        log_info "efivarfs is already mounted read-write"
        return 0
    fi

    if ! efi_mount_exists; then
        log_warn "efivarfs is not listed as a mounted filesystem"
        return 1
    fi

    log_warn "efivarfs is mounted read-only, attempting temporary remount as read-write"

    if mount -o remount,rw "$EFIVARFS_PATH" > "$remount_log" 2>&1; then
        if efi_mount_is_rw; then
            EFIVARFS_RESTORE_RO=1
            log_pass "efivarfs remounted read-write"
            return 0
        fi
    fi

    if mount -t efivarfs -o remount,rw efivarfs "$EFIVARFS_PATH" >> "$remount_log" 2>&1; then
        if efi_mount_is_rw; then
            EFIVARFS_RESTORE_RO=1
            log_pass "efivarfs remounted read-write"
            return 0
        fi
    fi

    log_warn "efivarfs remount read-write failed"
    system_log_file_excerpt "efivarfs-remount" "$remount_log" 40
    return 1
}

# Check whether an EFI variable was reported by efivar -l.
#
# Caller must define:
# EFI_LIST_LOG
efi_variable_list_contains() {
    var_name="$1"

    if [ -z "${EFI_LIST_LOG:-}" ]; then
        log_warn "EFI_LIST_LOG is not set"
        return 1
    fi

    grep -Fxq "$var_name" "$EFI_LIST_LOG" 2>/dev/null
}

# Find one EFI variable by its name suffix and print its GUID-qualified name.
# Args:
#   $1 - EFI variable name without the GUID, for example VendorDtbOverlays
#   $2 - file that receives efivar list output
# Diagnostic output is written to stderr so command-substitution callers only
# receive the variable name.
efi_find_variable_by_name() {
    efvbn_name="$1"
    efvbn_log_file="$2"
    efvbn_matches=""
    efvbn_count=0

    if [ -z "$efvbn_name" ] || [ -z "$efvbn_log_file" ]; then
        printf '%s\n' "efi_find_variable_by_name requires variable name and log file" >&2
        return 1
    fi

    if ! command -v efivar >/dev/null 2>&1; then
        printf '%s\n' "efivar command is unavailable" >&2
        return 1
    fi

    if ! efivar -l > "$efvbn_log_file" 2>&1; then
        printf '%s\n' "efivar could not list EFI variables" >&2
        return 1
    fi

    efvbn_matches="$(awk -v suffix="-$efvbn_name" '
        length($0) > length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix {
            print
        }
    ' "$efvbn_log_file")"
    efvbn_count="$(printf '%s\n' "$efvbn_matches" | awk 'NF { count++ } END { print count + 0 }')"

    if [ "$efvbn_count" -ne 1 ]; then
        printf '%s\n' "Expected one EFI variable named $efvbn_name, found $efvbn_count" >&2
        return 1
    fi

    printf '%s\n' "$efvbn_matches"
    return 0
}

# Return success when an EFI variable printout contains a text payload.
# Args:
#   $1 - EFI variable name in GUID-Name form
#   $2 - expected text payload, without a trailing newline
#   $3 - file that receives efivar print output
efi_text_variable_matches() {
    etvm_var_name="$1"
    etvm_value="$2"
    etvm_log_file="$3"
    etvm_data_file=""
    etvm_expected_bytes=""
    etvm_expected_pattern=""

    if [ -z "$etvm_var_name" ] || [ -z "$etvm_value" ] || [ -z "$etvm_log_file" ]; then
        log_warn "efi_text_variable_matches requires variable name, value, and log file"
        return 1
    fi

    if ! command -v efivar >/dev/null 2>&1; then
        log_warn "efivar command is unavailable"
        return 1
    fi

    if ! efivar -n "$etvm_var_name" -p > "$etvm_log_file" 2>&1; then
        return 1
    fi

    etvm_data_file="$(mktemp "${TMPDIR:-/tmp}/efivar_payload.XXXXXX" 2>/dev/null || true)"
    if [ -z "$etvm_data_file" ]; then
        log_warn "Could not create temporary EFI variable payload"
        return 1
    fi

    if ! printf '%s' "$etvm_value" > "$etvm_data_file"; then
        log_warn "Could not write temporary EFI variable payload"
        rm -f "$etvm_data_file"
        return 1
    fi

    etvm_expected_bytes="$(od -An -tx1 -v "$etvm_data_file" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
    rm -f "$etvm_data_file"

    if [ -z "$etvm_expected_bytes" ]; then
        log_warn "Could not derive EFI variable payload bytes"
        return 1
    fi

    etvm_expected_pattern="$(printf '%s\n' "$etvm_expected_bytes" | sed 's/ /[[:space:]][[:space:]]*/g')"
    grep -Eq "$etvm_expected_pattern" "$etvm_log_file"
}

# Write a text payload to an EFI variable and verify its printed byte value.
# Args:
#   $1 - EFI variable name in GUID-Name form
#   $2 - text payload, written without a trailing newline
#   $3 - file that receives efivar write and print output
# The caller is responsible for arranging efi_restore_efivarfs_ro during
# cleanup when efi_try_remount_rw changes the mount state.
efi_write_text_variable() {
    ewtv_var_name="$1"
    ewtv_value="$2"
    ewtv_log_file="$3"
    ewtv_data_file=""

    if [ -z "$ewtv_var_name" ] || [ -z "$ewtv_value" ] || [ -z "$ewtv_log_file" ]; then
        log_warn "efi_write_text_variable requires variable name, value, and log file"
        return 1
    fi

    if ! command -v efivar >/dev/null 2>&1; then
        log_warn "efivar command is unavailable"
        return 1
    fi

    if ! efi_mount_is_rw && ! efi_try_remount_rw; then
        log_warn "efivarfs is not writable"
        return 1
    fi

    ewtv_data_file="$(mktemp "${TMPDIR:-/tmp}/efivar_payload.XXXXXX" 2>/dev/null || true)"
    if [ -z "$ewtv_data_file" ]; then
        log_warn "Could not create temporary EFI variable payload"
        return 1
    fi

    if ! printf '%s' "$ewtv_value" > "$ewtv_data_file"; then
        log_warn "Could not write temporary EFI variable payload"
        rm -f "$ewtv_data_file"
        return 1
    fi

    if ! efivar -n "$ewtv_var_name" -w -f "$ewtv_data_file" > "$ewtv_log_file" 2>&1; then
        log_warn "efivar write failed for $ewtv_var_name"
        rm -f "$ewtv_data_file"
        return 1
    fi

    rm -f "$ewtv_data_file"

    if ! efi_text_variable_matches \
        "$ewtv_var_name" \
        "$ewtv_value" \
        "$ewtv_log_file"; then
        log_warn "EFI variable printout does not contain the requested payload"
        return 1
    fi

    sync
    log_info "EFI variable updated and verified: $ewtv_var_name"
    return 0
}

# ---------------------------------------------------------------------------
# Compatibility wrappers for existing EFI_Variable_Validation/run.sh names
# ---------------------------------------------------------------------------
# These wrappers let existing tests move helpers to lib_system.sh with minimal
# run.sh churn. New callers should prefer the prefixed function names above.

write_trial_boot_status_payload() {
    efi_write_trial_boot_status_payload "$@"
}

log_file_excerpt() {
    system_log_file_excerpt "$@"
}

require_grep_in_file() {
    system_require_grep_in_file "$@"
}

require_hex_payload_in_file() {
    efi_require_trial_boot_status_payload "$@"
}

require_os_indications_supported_value() {
    efi_require_os_indications_supported_value "$@"
}
