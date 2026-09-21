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
. "$TOOLS/lib_thermal.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_system.sh"
TESTNAME="Thermal_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

THERMAL_LOAD_ENABLE="${THERMAL_LOAD_ENABLE:-0}"
THERMAL_LOAD_SECONDS="${THERMAL_LOAD_SECONDS:-15}"
THERMAL_LOAD_WORKERS="${THERMAL_LOAD_WORKERS:-1}"
THERMAL_RECOVERY_SECONDS="${THERMAL_RECOVERY_SECONDS:-5}"
THERMAL_MIN_RISE_MC="${THERMAL_MIN_RISE_MC:-1000}"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
DT_ROOT=""

# cleanup
# Takes no arguments and produces no stdout. Stops only the controlled-load
# process started by this suite, preserves retained evidence, and restores the
# runner stdout capture when the script exits or receives a handled signal.
# Returns through runner_stdout_cleanup with the incoming trap status.
cleanup() {
    cleanup_status=$?
    thermal_stop_controlled_load >/dev/null 2>&1 || true
    runner_stdout_cleanup "$cleanup_status"
}

# usage
# Takes no arguments, prints the supported CLI contract to stdout, and has no
# side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --load-enable 0|1             Optional stress phase, default: 0" \
        "  --load-seconds SECONDS        Stress duration, default: 15" \
        "  --load-workers COUNT          CPU workers, default: 1" \
        "  --recovery-seconds SECONDS    Recovery sample delay, default: 5" \
        "  --min-rise-mc MILLICELSIUS    Informational response threshold, default: 1000" \
        "  -h, --help" \
        "Thermal zones, trips, and cooling devices are discovered dynamically." \
        "CLI options override environment variables."
}

# parse_args <suite-arguments...>
# Applies option values to the suite configuration globals. Produces no stdout,
# returns 0 on success or 2 for a missing or unknown argument, and does not
# start validation or mutate target state.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --load-enable)
                [ "$#" -ge 2 ] || return 2
                THERMAL_LOAD_ENABLE="$2"
                shift 2
                ;;
            --load-seconds)
                [ "$#" -ge 2 ] || return 2
                THERMAL_LOAD_SECONDS="$2"
                shift 2
                ;;
            --load-workers)
                [ "$#" -ge 2 ] || return 2
                THERMAL_LOAD_WORKERS="$2"
                shift 2
                ;;
            --recovery-seconds)
                [ "$#" -ge 2 ] || return 2
                THERMAL_RECOVERY_SECONDS="$2"
                shift 2
                ;;
            --min-rise-mc)
                [ "$#" -ge 2 ] || return 2
                THERMAL_MIN_RISE_MC="$2"
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

test_result_init "$TESTNAME" "$RES_FILE"
trap cleanup EXIT HUP INT TERM
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "Thermal validation: checking DT declarations, runtime zones, trips, cooling bindings, and optional controlled-load response"
log_info "Configuration: load_enable=$THERMAL_LOAD_ENABLE load_seconds=${THERMAL_LOAD_SECONDS}s workers=$THERMAL_LOAD_WORKERS recovery_seconds=${THERMAL_RECOVERY_SECONDS}s min_rise_mC=$THERMAL_MIN_RISE_MC"
log_info "[THERMAL-SELECTION] capability=dynamic load_policy=$THERMAL_LOAD_ENABLE"

for thermal_value in \
    "$THERMAL_LOAD_SECONDS" \
    "$THERMAL_LOAD_WORKERS" \
    "$THERMAL_RECOVERY_SECONDS" \
    "$THERMAL_MIN_RISE_MC"; do
    if ! system_is_uint "$thermal_value"; then
        test_result_record "FAIL" "Thermal load settings must be unsigned integers"
        test_result_finish
    fi
done

if [ "$THERMAL_LOAD_SECONDS" -eq 0 ] || [ "$THERMAL_LOAD_WORKERS" -eq 0 ]; then
    test_result_record "FAIL" "Thermal load duration and worker count must be positive integers"
    test_result_finish
fi

case "$THERMAL_LOAD_ENABLE" in
    0|1)
        ;;
    *)
        test_result_record "FAIL" "Thermal load enable must be 0 or 1"
        test_result_finish
        ;;
esac

for thermal_dt_candidate in /proc/device-tree /sys/firmware/devicetree/base; do
    [ -d "$thermal_dt_candidate" ] || continue
    DT_ROOT=$(readlink -f "$thermal_dt_candidate")
    break
done

if [ -z "$DT_ROOT" ]; then
    test_result_record "SKIP" "Runtime device tree is unavailable for thermal applicability"
    test_result_finish
fi

thermal_declared_count=0
if [ -d "$DT_ROOT/thermal-zones" ]; then
    for thermal_declared_zone in "$DT_ROOT/thermal-zones"/*; do
        [ -d "$thermal_declared_zone" ] || continue
        dt_node_enabled "$thermal_declared_zone" || continue
        thermal_declared_count=$((thermal_declared_count + 1))
    done
fi

if [ "$thermal_declared_count" -eq 0 ]; then
    log_info "[THERMAL-DISCOVERY] dt_root=$DT_ROOT enabled_zones=0 reason=no-enabled-thermal-zones"
    test_result_record "SKIP" "Runtime device tree has no enabled thermal zones"
    test_result_finish
fi

log_info "[THERMAL-DISCOVERY] dt_root=$DT_ROOT enabled_zones=$thermal_declared_count"

dt_validate_thermal_runtime "$DT_ROOT" "$RESULT_DIR"

if thermal_capture_policy "$RESULT_DIR/thermal_policy.tsv"; then
    log_info "[THERMAL-POLICY] trips=$THERMAL_TRIP_COUNT bindings=$THERMAL_BINDING_COUNT invalid=0 artifact=$RESULT_DIR/thermal_policy.tsv"
    thermal_log_policy "$RESULT_DIR/thermal_policy.tsv" 64
    if [ "$THERMAL_TRIP_COUNT" -gt 0 ]; then
        test_result_record "PASS" "Thermal runtime exposes $THERMAL_TRIP_COUNT valid trip point(s) and $THERMAL_BINDING_COUNT cooling binding(s)"
    else
        test_result_record "SKIP" "No runtime trip-point attributes are exposed"
    fi
else
    log_fail "[THERMAL-POLICY] trips=$THERMAL_TRIP_COUNT bindings=$THERMAL_BINDING_COUNT invalid=$THERMAL_POLICY_INVALID_COUNT artifact=$RESULT_DIR/thermal_policy.tsv"
    thermal_log_policy "$RESULT_DIR/thermal_policy.tsv" 64
    test_result_record "FAIL" "Thermal policy exposes $THERMAL_POLICY_INVALID_COUNT malformed trip attribute(s)"
fi

if [ "$THERMAL_LOAD_ENABLE" = "1" ]; then
    if ! command -v stress-ng >/dev/null 2>&1; then
        test_result_record "SKIP" "Controlled thermal load was requested but stress-ng is not image-provided"
    else
        : >"$RESULT_DIR/thermal_samples.tsv"
        if ! thermal_capture_sample "$RESULT_DIR/thermal_samples.tsv" before; then
            test_result_record "FAIL" "No readable temperature was available before controlled load"
        else
            load_timeout=$((THERMAL_LOAD_SECONDS + 10))
            log_info "[THERMAL-LOAD] action=start tool=stress-ng workers=$THERMAL_LOAD_WORKERS duration=${THERMAL_LOAD_SECONDS}s timeout=${load_timeout}s sample_interval=1s"
            thermal_run_controlled_load \
                "$RESULT_DIR/thermal_samples.tsv" \
                "$RESULT_DIR/stress-ng.log" \
                "$THERMAL_LOAD_SECONDS" \
                "$THERMAL_LOAD_WORKERS"
            load_rc=$?
            thermal_capture_sample "$RESULT_DIR/thermal_samples.tsv" after
            after_sample_rc=$?

            if [ "$load_rc" -ne 0 ]; then
                log_file_with_label "THERMAL-STRESS" "$RESULT_DIR/stress-ng.log" 25
                test_result_record "FAIL" "Controlled thermal load failed, rc=$load_rc artifact=$RESULT_DIR/stress-ng.log"
            elif [ "$after_sample_rc" -ne 0 ]; then
                test_result_record "FAIL" "No readable temperature was available after controlled load"
            else
                max_rise=$(thermal_sample_max_rise "$RESULT_DIR/thermal_samples.tsv" 2>/dev/null || true)
                max_cooling_increase=$(thermal_sample_max_cooling_increase "$RESULT_DIR/thermal_samples.tsv" 2>/dev/null || true)
                log_info "[THERMAL-LOAD] action=complete rc=0 sample_failures=$THERMAL_LOAD_SAMPLE_FAILURES max_rise_mC=${max_rise:-unknown} max_cooling_increase=${max_cooling_increase:-unavailable} samples=$RESULT_DIR/thermal_samples.tsv"
                test_result_record "PASS" "Controlled CPU load completed and thermal telemetry remained readable"
                if [ -n "$max_rise" ] && [ "$max_rise" -ge "$THERMAL_MIN_RISE_MC" ]; then
                    test_result_record "PASS" "Thermal response was observed, maximum temperature rise=${max_rise}mC"
                else
                    test_result_record "SKIP" "No temperature rise of at least ${THERMAL_MIN_RISE_MC}mC was observed during the bounded load"
                fi
                if [ -n "$max_cooling_increase" ] && [ "$max_cooling_increase" -gt 0 ]; then
                    test_result_record "PASS" "A cooling-device state increase was observed during controlled load"
                else
                    test_result_record "SKIP" "No cooling-device state increase was required during the bounded load"
                fi
            fi

            if [ "$THERMAL_RECOVERY_SECONDS" -gt 0 ]; then
                sleep "$THERMAL_RECOVERY_SECONDS"
                if thermal_capture_sample "$RESULT_DIR/thermal_samples.tsv" recovery; then
                    test_result_record "PASS" "Thermal telemetry remained readable after ${THERMAL_RECOVERY_SECONDS}s recovery"
                else
                    test_result_record "FAIL" "Thermal telemetry became unreadable during recovery"
                fi
            fi
            if ! thermal_log_sample_summary "$RESULT_DIR/thermal_samples.tsv"; then
                test_result_record "FAIL" "Thermal sample summary generation failed, samples=$RESULT_DIR/thermal_samples.tsv"
            fi
        fi
    fi
else
    test_result_record "SKIP" "Controlled thermal load is disabled by default, set --load-enable 1 to opt in"
fi

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'thermal|tsens|lmh|cooling|cpufreq' \
    'critical temperature reached'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for thermal health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "THERMAL-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "Thermal-related kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent thermal-related kernel errors were found"
fi

test_result_finish
