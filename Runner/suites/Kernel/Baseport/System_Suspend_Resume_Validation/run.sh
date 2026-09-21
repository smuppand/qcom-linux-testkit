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
# shellcheck disable=SC1091
. "$TOOLS/lib_system.sh"
TESTNAME="System_Suspend_Resume_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

SYSTEM_SUSPEND_ENABLE="${SYSTEM_SUSPEND_ENABLE:-0}"
SYSTEM_SUSPEND_SECONDS="${SYSTEM_SUSPEND_SECONDS:-30}"
SYSTEM_SUSPEND_MODE="${SYSTEM_SUSPEND_MODE:-mem}"
SYSTEM_RTC_DEVICE="${SYSTEM_RTC_DEVICE:-}"
SYSTEM_RESUME_TIMEOUT="${SYSTEM_RESUME_TIMEOUT:-30}"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
SUSPEND_ALARM_OWNED=0
WAKEALARM_PATH=""

# cleanup_alarm
# Takes no arguments and produces diagnostic logs only. Clears and verifies a
# test-owned RTC alarm, returns 0 when no cleanup is needed or cleanup succeeds,
# returns 1 on restoration failure, and resets ownership only after success.
cleanup_alarm() {
    if [ "$SUSPEND_ALARM_OWNED" -ne 1 ] || [ -z "$WAKEALARM_PATH" ]; then
        return 0
    fi

    log_warn "[SUSPEND-RESTORE] rtc=${RTC_DEVICE:-unknown} action=clear trigger=cleanup"
    if system_clear_rtc_alarm \
        "$WAKEALARM_PATH" \
        "$RESULT_DIR/wakealarm-restore.log"; then
        SUSPEND_ALARM_OWNED=0
        return 0
    fi

    log_fail "[SUSPEND-RESTORE] rtc=${RTC_DEVICE:-unknown} action=clear status=failed artifact=$RESULT_DIR/wakealarm-restore.log"
    return 1
}

# cleanup [exit-status]
# Accepts the status selected by the EXIT or signal trap and produces diagnostic
# logs only. Performs emergency RTC alarm restoration, preserves retained
# evidence, and restores runner stdout. A restoration failure changes a zero
# status to 1. Returns through runner_stdout_cleanup or exits with that status.
cleanup() {
    cleanup_status="${1:-$?}"
    if ! cleanup_alarm; then
        log_fail "Emergency RTC alarm cleanup failed after exit or interruption"
        if [ "$cleanup_status" -eq 0 ]; then
            cleanup_status=1
        fi
    fi

    if [ -n "${__RUN_STDOUT_ACTIVE:-}" ]; then
        runner_stdout_cleanup "$cleanup_status"
    fi

    trap - EXIT HUP INT TERM
    exit "$cleanup_status"
}

# usage
# Takes no arguments, prints the CLI contract to stdout, returns 0, and has no
# side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --enable 0|1                Required safety opt-in, default: 0" \
        "  --suspend-seconds SECONDS   RTC wake interval, default: 30" \
        "  --suspend-mode MODE         Kernel-exposed suspend mode, default: mem" \
        "  --rtc-device PATH           Override automatic wake-capable RTC selection" \
        "  --resume-timeout SECONDS    Device recovery wait, default: 30" \
        "  -h, --help" \
        "Devices, drivers, remote processors, wake sources, and RTC are discovered dynamically." \
        "CLI options override environment variables."
}

# parse_args <arguments...>
# Parses CLI options into SYSTEM_* globals without producing stdout. Returns 0
# on success or 2 for an unknown option or missing value and has no other side
# effects.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --enable)
                [ "$#" -ge 2 ] || return 2
                SYSTEM_SUSPEND_ENABLE="$2"
                shift 2
                ;;
            --suspend-seconds)
                [ "$#" -ge 2 ] || return 2
                SYSTEM_SUSPEND_SECONDS="$2"
                shift 2
                ;;
            --suspend-mode)
                [ "$#" -ge 2 ] || return 2
                SYSTEM_SUSPEND_MODE="$2"
                shift 2
                ;;
            --rtc-device)
                [ "$#" -ge 2 ] || return 2
                SYSTEM_RTC_DEVICE="$2"
                shift 2
                ;;
            --resume-timeout)
                [ "$#" -ge 2 ] || return 2
                SYSTEM_RESUME_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

parse_args "$@" || {
    usage >&2
    exit 2
}

trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

test_result_init "$TESTNAME" "$RES_FILE"
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "System suspend/resume validation: snapshotting device bindings and wake sources around an RTC-triggered suspend transaction"
log_info "Configuration: enable=$SYSTEM_SUSPEND_ENABLE mode=$SYSTEM_SUSPEND_MODE duration=${SYSTEM_SUSPEND_SECONDS}s rtc=${SYSTEM_RTC_DEVICE:-auto} resume_timeout=${SYSTEM_RESUME_TIMEOUT}s"
rtc_selection="auto"
if [ -n "$SYSTEM_RTC_DEVICE" ]; then
    rtc_selection="override"
fi
log_info "[SUSPEND-POLICY] applicability=dynamic rtc_selection=$rtc_selection safety_opt_in=$SYSTEM_SUSPEND_ENABLE"

if [ "$SYSTEM_SUSPEND_ENABLE" != "1" ]; then
    test_result_record "SKIP" "System suspend is disabled by default, set --enable 1 only with an independent recovery console"
    test_result_finish
fi

if ! system_is_uint "$SYSTEM_SUSPEND_SECONDS" ||
   ! system_is_uint "$SYSTEM_RESUME_TIMEOUT" ||
   [ "$SYSTEM_SUSPEND_SECONDS" -eq 0 ] ||
   [ "$SYSTEM_RESUME_TIMEOUT" -eq 0 ]; then
    test_result_record "FAIL" "Suspend duration and resume timeout must be positive integers"
    test_result_finish
fi

if [ "$(id -u)" -ne 0 ]; then
    test_result_record "SKIP" "Root privilege is required for system suspend"
    test_result_finish
fi

if [ ! -r /sys/power/state ] ||
   ! grep -qw "$SYSTEM_SUSPEND_MODE" /sys/power/state; then
    test_result_record "SKIP" "Requested suspend mode $SYSTEM_SUSPEND_MODE is not exposed by /sys/power/state"
    test_result_finish
fi

SUSPEND_PROVIDER="direct-sysfs"
if command -v rtcwake >/dev/null 2>&1; then
    SUSPEND_PROVIDER="native-rtcwake"
elif [ ! -w /sys/power/state ]; then
    test_result_record "SKIP" "Neither rtcwake nor writable kernel suspend sysfs is available"
    test_result_finish
fi

if ! system_capture_rtc_inventory \
    "$RESULT_DIR/rtc_candidates.tsv" \
    "$SYSTEM_RTC_DEVICE"; then
    test_result_record "FAIL" "RTC candidate inventory could not be captured"
    test_result_finish
fi
system_log_rtc_inventory "$RESULT_DIR/rtc_candidates.tsv" 16
RTC_DEVICE=$(system_select_rtc_device "$SYSTEM_RTC_DEVICE" 2>/dev/null || true)
if [ -z "$RTC_DEVICE" ]; then
    if [ -n "$SYSTEM_RTC_DEVICE" ]; then
        test_result_record "FAIL" "Requested RTC $SYSTEM_RTC_DEVICE is not a usable wake device, inspect $RESULT_DIR/rtc_candidates.tsv"
    else
        test_result_record "SKIP" "No usable RTC wake device was discovered"
    fi
    test_result_finish
fi
RTC_NAME=${RTC_DEVICE##*/}
WAKEALARM_PATH="/sys/class/rtc/$RTC_NAME/wakealarm"
if [ ! -r "$WAKEALARM_PATH" ] || [ ! -w "$WAKEALARM_PATH" ]; then
    test_result_record "SKIP" "RTC $RTC_DEVICE does not expose an accessible wake alarm at $WAKEALARM_PATH"
    test_result_finish
fi
if ! PREVIOUS_ALARM=$(cat "$WAKEALARM_PATH" 2>/dev/null); then
    test_result_record "FAIL" "RTC $RTC_DEVICE wake alarm state could not be read"
    test_result_finish
fi
if [ -n "$PREVIOUS_ALARM" ] && [ "$PREVIOUS_ALARM" != "0" ]; then
    log_info "[SUSPEND-SAFETY] rtc=$RTC_DEVICE existing_alarm=$PREVIOUS_ALARM action=refused"
    test_result_record "SKIP" "RTC $RTC_DEVICE already has a wake alarm, refusing to overwrite external state"
    test_result_finish
fi

log_info "[SUSPEND-DISCOVERY] mode=$SYSTEM_SUSPEND_MODE rtc=$RTC_DEVICE existing_alarm=${PREVIOUS_ALARM:-none} privilege=root provider=$SUSPEND_PROVIDER"

if ! system_capture_bound_devices "$RESULT_DIR/devices-before.tsv"; then
    test_result_record "FAIL" "Pre-suspend device binding snapshot could not be captured"
    test_result_finish
fi
before_device_count=$(wc -l <"$RESULT_DIR/devices-before.tsv" | tr -d '[:space:]')
if ! system_capture_remoteproc_states "$RESULT_DIR/remoteproc-before.tsv"; then
    test_result_record "FAIL" "Pre-suspend remote processor snapshot could not be captured"
    test_result_finish
fi
log_file_with_label "SUSPEND-REMOTEPROC-BEFORE" "$RESULT_DIR/remoteproc-before.tsv" 20
system_capture_wakeup_sources "$RESULT_DIR/wakeup-before.log"
wakeup_before_rc=$?
cat /proc/uptime >"$RESULT_DIR/uptime-before.log" 2>/dev/null || true
cat /proc/sys/kernel/random/boot_id >"$RESULT_DIR/boot-id-before.log" 2>/dev/null || true
BOOT_ID_BEFORE=$(sed -n '1p' "$RESULT_DIR/boot-id-before.log" 2>/dev/null)
UPTIME_BEFORE=$(sed -n '1p' "$RESULT_DIR/uptime-before.log" 2>/dev/null)
MONOTONIC_BEFORE=$(get_monotonic_seconds)
log_info "[SUSPEND-SNAPSHOT] phase=before boot_id=${BOOT_ID_BEFORE:-unavailable} uptime=${UPTIME_BEFORE:-unavailable} devices=$before_device_count"
sync

operation_timeout=$((SYSTEM_SUSPEND_SECONDS + SYSTEM_RESUME_TIMEOUT + 15))
log_info "[SUSPEND-ACTION] provider=$SUSPEND_PROVIDER mode=$SYSTEM_SUSPEND_MODE rtc=$RTC_DEVICE duration=${SYSTEM_SUSPEND_SECONDS}s timeout=${operation_timeout}s devices_before=$before_device_count"
SUSPEND_ALARM_OWNED=1
if [ "$SUSPEND_PROVIDER" = "native-rtcwake" ]; then
    run_with_timeout_log \
        "$operation_timeout" \
        "$RESULT_DIR/suspend-transaction.log" \
        rtcwake -d "$RTC_DEVICE" -m "$SYSTEM_SUSPEND_MODE" -s "$SYSTEM_SUSPEND_SECONDS"
    rtcwake_rc=$?
else
    if system_arm_rtc_alarm \
        "$WAKEALARM_PATH" \
        "$SYSTEM_SUSPEND_SECONDS" \
        "$RESULT_DIR/wakealarm-arm.log"; then
        log_file_with_label "SUSPEND-ALARM" "$RESULT_DIR/wakealarm-arm.log" 10
        # shellcheck disable=SC2016
        run_with_timeout_log \
            "$operation_timeout" \
            "$RESULT_DIR/suspend-transaction.log" \
            sh -c 'printf "%s\n" "$1" > /sys/power/state' \
            suspend-sysfs "$SYSTEM_SUSPEND_MODE"
        rtcwake_rc=$?
    else
        rtcwake_rc=1
        log_file_with_label "SUSPEND-ALARM" "$RESULT_DIR/wakealarm-arm.log" 10
    fi
fi
MONOTONIC_AFTER=$(get_monotonic_seconds)
log_file_with_label "SUSPEND-TRANSACTION" "$RESULT_DIR/suspend-transaction.log" 25

if [ "$rtcwake_rc" -ne 0 ]; then
    test_result_record "FAIL" "RTC-triggered suspend did not complete through $SUSPEND_PROVIDER, rc=$rtcwake_rc artifact=$RESULT_DIR/suspend-transaction.log"
else
    suspend_elapsed=$((MONOTONIC_AFTER - MONOTONIC_BEFORE))
    suspend_min_elapsed=$((SYSTEM_SUSPEND_SECONDS - 2))
    if [ "$suspend_min_elapsed" -lt 1 ]; then
        suspend_min_elapsed=1
    fi
    log_info "[SUSPEND-DURATION] requested=${SYSTEM_SUSPEND_SECONDS}s observed=${suspend_elapsed}s minimum=${suspend_min_elapsed}s source=monotonic"
    if [ "$suspend_elapsed" -lt "$suspend_min_elapsed" ]; then
        test_result_record "FAIL" "Suspend provider returned without the requested wake interval, requested=${SYSTEM_SUSPEND_SECONDS}s observed=${suspend_elapsed}s"
    else
        test_result_record "PASS" "RTC-triggered $SYSTEM_SUSPEND_MODE suspend returned after ${suspend_elapsed}s through $SUSPEND_PROVIDER"
    fi
fi

if ! POST_ALARM=$(cat "$WAKEALARM_PATH" 2>/dev/null); then
    test_result_record "FAIL" "RTC wake alarm state could not be read after the suspend transaction"
elif [ -n "$POST_ALARM" ] && [ "$POST_ALARM" != "0" ]; then
    log_warn "[SUSPEND-RESTORE] rtc=$RTC_DEVICE stale_alarm=$POST_ALARM action=clear"
    if cleanup_alarm; then
        test_result_record "PASS" "RTC wake alarm created by the test was cleared"
    else
        test_result_record "FAIL" "RTC wake alarm cleanup failed, artifact=$RESULT_DIR/wakealarm-restore.log"
    fi
else
    SUSPEND_ALARM_OWNED=0
    log_info "[SUSPEND-RESTORE] rtc=$RTC_DEVICE alarm=clear action=none"
fi

if [ "$rtcwake_rc" -eq 0 ]; then
    recovery_start=$(get_monotonic_seconds)
    if system_wait_for_bound_devices \
        "$RESULT_DIR/devices-before.tsv" \
        "$RESULT_DIR/devices-after.tsv" \
        "$RESULT_DIR/devices-missing.tsv" \
        "$SYSTEM_RESUME_TIMEOUT"; then
        after_device_count=$(wc -l <"$RESULT_DIR/devices-after.tsv" | tr -d '[:space:]')
        log_info "[SUSPEND-DEVICES] before=$before_device_count after=$after_device_count missing=0"
        test_result_record "PASS" "All $before_device_count pre-suspend device and driver bindings returned"
    else
        missing_count=$(wc -l <"$RESULT_DIR/devices-missing.tsv" | tr -d '[:space:]')
        log_fail "[SUSPEND-DEVICES] before=$before_device_count missing=$missing_count artifact=$RESULT_DIR/devices-missing.tsv"
        log_file_with_label "SUSPEND-DEVICE-MISSING" "$RESULT_DIR/devices-missing.tsv" 30
        test_result_record "FAIL" "$missing_count pre-suspend device binding(s) did not return within ${SYSTEM_RESUME_TIMEOUT}s"
    fi

    system_capture_wakeup_sources "$RESULT_DIR/wakeup-after.log"
    wakeup_after_rc=$?
    recovery_now=$(get_monotonic_seconds)
    recovery_elapsed=$((recovery_now - recovery_start))
    recovery_remaining=$((SYSTEM_RESUME_TIMEOUT - recovery_elapsed))
    if [ "$recovery_remaining" -lt 0 ]; then
        recovery_remaining=0
    fi
    if system_wait_for_remoteproc_states \
        "$RESULT_DIR/remoteproc-before.tsv" \
        "$RESULT_DIR/remoteproc-after.tsv" \
        "$RESULT_DIR/remoteproc-changed.tsv" \
        "$recovery_remaining"; then
        remoteproc_recovered=1
    else
        remoteproc_recovered=0
    fi
    cat /proc/uptime >"$RESULT_DIR/uptime-after.log" 2>/dev/null || true
    cat /proc/sys/kernel/random/boot_id >"$RESULT_DIR/boot-id-after.log" 2>/dev/null || true
    BOOT_ID_AFTER=$(sed -n '1p' "$RESULT_DIR/boot-id-after.log" 2>/dev/null)
    UPTIME_AFTER=$(sed -n '1p' "$RESULT_DIR/uptime-after.log" 2>/dev/null)
    log_info "[SUSPEND-SNAPSHOT] phase=after boot_id=${BOOT_ID_AFTER:-unavailable} uptime=${UPTIME_AFTER:-unavailable}"

    if [ -n "$BOOT_ID_BEFORE" ] && [ "$BOOT_ID_BEFORE" = "$BOOT_ID_AFTER" ]; then
        test_result_record "PASS" "Boot identity is unchanged, confirming resume rather than reboot"
    elif [ -z "$BOOT_ID_BEFORE" ] || [ -z "$BOOT_ID_AFTER" ]; then
        test_result_record "SKIP" "Boot identity is unavailable, resume was established only by the $SUSPEND_PROVIDER return path"
    else
        test_result_record "FAIL" "Boot identity changed across the operation, the target rebooted instead of resuming"
    fi

    if [ "$remoteproc_recovered" -eq 1 ]; then
        test_result_record "PASS" "Remote processor states match the pre-suspend snapshot"
        log_file_with_label "SUSPEND-REMOTEPROC-AFTER" "$RESULT_DIR/remoteproc-after.tsv" 20
    else
        remoteproc_changed=$(wc -l <"$RESULT_DIR/remoteproc-changed.tsv" | tr -d '[:space:]')
        log_fail "[SUSPEND-REMOTEPROC] changed=$remoteproc_changed artifact=$RESULT_DIR/remoteproc-changed.tsv"
        log_file_with_label "SUSPEND-REMOTEPROC-CHANGED" "$RESULT_DIR/remoteproc-changed.tsv" 20
        test_result_record "FAIL" "$remoteproc_changed remote processor state record(s) did not recover after resume"
    fi

    if [ "$wakeup_before_rc" -eq 0 ] && [ "$wakeup_after_rc" -eq 0 ]; then
        log_info "[SUSPEND-WAKE] before=$RESULT_DIR/wakeup-before.log after=$RESULT_DIR/wakeup-after.log"
        log_file_with_label "SUSPEND-WAKE-BEFORE" "$RESULT_DIR/wakeup-before.log" 12
        log_file_with_label "SUSPEND-WAKE-AFTER" "$RESULT_DIR/wakeup-after.log" 12
        test_result_record "PASS" "Wake-source evidence was captured before and after resume"
    else
        test_result_record "SKIP" "Wake-source counters are not accessible on this image"
    fi
fi

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'PM|suspend|resume|wakeup|remoteproc|genpd|regulator' \
    'Freezing user space processes|Suspending console|ACPI: PM|PM: suspend entry|PM: suspend exit'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for suspend health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "SUSPEND-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "Suspend or resume kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent suspend or resume kernel errors were found"
fi

test_result_finish
