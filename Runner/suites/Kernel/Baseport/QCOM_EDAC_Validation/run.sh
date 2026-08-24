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
TESTNAME="QCOM_EDAC_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

STRICT_CE="${EDAC_STRICT_CE:-0}"
OBSERVE_SECONDS="${EDAC_OBSERVE_SECONDS:-2}"

# usage
# Prints supported command-line options and returns success.
usage() {
    printf '%s\n' "Usage: $0 [--strict-ce 0|1] [--observe-seconds N]"
}

# parse_args <arguments...>
# Parses command-line overrides and exits for help or invalid input.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --strict-ce)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    exit 2
                }
                STRICT_CE="$2"
                shift 2
                ;;
            --observe-seconds)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    exit 2
                }
                OBSERVE_SECONDS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_fail "Unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
    done
}

# snapshot_edac_counters <output-file>
# Writes one "path|value" record for every Qualcomm LLCC EDAC CE and UE
# counter. Returns 0 when at least one readable counter is found, otherwise 1.
snapshot_edac_counters() {
    output_file="$1"
    found=0
    : >"$output_file"

    for counter_file in \
        /sys/devices/system/edac/qcom-llcc/*/ce_count \
        /sys/devices/system/edac/qcom-llcc/*/ue_count; do
        [ -r "$counter_file" ] || continue
        counter_value=$(tr -d '[:space:]' <"$counter_file")
        case "$counter_value" in
            ''|*[!0-9]*)
                continue
                ;;
        esac
        printf '%s|%s\n' "$counter_file" "$counter_value" >>"$output_file"
        found=1
    done

    [ "$found" -eq 1 ]
}

# counter_value_from_snapshot <snapshot> <path>
# Prints a counter value from a snapshot and returns 0 when present, otherwise
# returns 1.
counter_value_from_snapshot() {
    snapshot_file="$1"
    counter_path="$2"
    awk -F '|' -v path="$counter_path" '$1 == path { print $2; found=1; exit } END { exit !found }' "$snapshot_file"
}

parse_args "$@"

case "$STRICT_CE" in
    0|1)
        ;;
    *)
        log_fail "--strict-ce must be 0 or 1"
        exit 2
        ;;
esac

case "$OBSERVE_SECONDS" in
    ''|*[!0-9]*)
        log_fail "--observe-seconds must be a non-negative integer"
        exit 2
        ;;
esac

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
rm -f \
    "$SCRIPT_DIR/edac_counters_before.log" \
    "$SCRIPT_DIR/edac_counters_after.log"

baseline_file="$SCRIPT_DIR/edac_counters_before.log"
final_file="$SCRIPT_DIR/edac_counters_after.log"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Configuration: strict_ce=$STRICT_CE observe_seconds=$OBSERVE_SECONDS"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies awk grep tr sleep readlink basename; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

edac_platform_device=""
for candidate in /sys/bus/platform/devices/qcom_llcc_edac*; do
    [ -d "$candidate" ] || continue
    edac_platform_device="$candidate"
    break
done

if [ -z "$edac_platform_device" ] && [ ! -d /sys/devices/system/edac/qcom-llcc ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: Qualcomm LLCC EDAC is not exposed on this platform"
fi

for config_name in CONFIG_EDAC CONFIG_EDAC_QCOM; do
    if config_line=$(kernel_config_value "$config_name" 2>/dev/null); then
        log_info "[EDAC-CONFIG] $config_line"
        case "$config_line" in
            *=y|*=m)
                test_result_record "PASS" "$config_name is enabled"
                ;;
            *)
                test_result_record "FAIL" "$config_name is disabled for an exposed Qualcomm EDAC device"
                ;;
        esac
    else
        log_info "$config_name could not be checked because the running kernel configuration is unavailable"
    fi
done

if [ -n "$edac_platform_device" ]; then
    if driver_name=$(platform_device_driver_name "$edac_platform_device"); then
        if [ "$driver_name" = "qcom_llcc_edac" ]; then
            test_result_record "PASS" "Qualcomm LLCC EDAC platform device is bound"
        else
            test_result_record "FAIL" "Qualcomm LLCC EDAC device uses an unexpected driver: $driver_name"
        fi
    else
        test_result_record "FAIL" "Qualcomm LLCC EDAC platform device is unbound"
    fi
fi

if [ ! -d /sys/devices/system/edac/qcom-llcc ]; then
    test_result_record "FAIL" "Qualcomm LLCC EDAC sysfs hierarchy is missing"
elif snapshot_edac_counters "$baseline_file"; then
    test_result_record "PASS" "Qualcomm LLCC EDAC counters are readable"
else
    test_result_record "FAIL" "No readable Qualcomm LLCC EDAC bank counters were found"
fi

if [ -s "$baseline_file" ]; then
    while IFS='|' read -r counter_path counter_value; do
        log_info "[EDAC-BASELINE] path=$counter_path value=$counter_value"
        case "$counter_path" in
            */ue_count)
                if [ "$counter_value" -gt 0 ]; then
                    test_result_record "FAIL" "Uncorrectable EDAC errors are present: path=$counter_path count=$counter_value"
                fi
                ;;
            */ce_count)
                if [ "$counter_value" -gt 0 ] && [ "$STRICT_CE" -eq 1 ]; then
                    test_result_record "FAIL" "Correctable EDAC errors are present in strict mode: path=$counter_path count=$counter_value"
                elif [ "$counter_value" -gt 0 ]; then
                    log_warn "Correctable EDAC errors are present at baseline: path=$counter_path count=$counter_value"
                fi
                ;;
        esac
    done <"$baseline_file"

    sleep "$OBSERVE_SECONDS"
    snapshot_edac_counters "$final_file" || true

    while IFS='|' read -r counter_path baseline_value; do
        final_value=$(counter_value_from_snapshot "$final_file" "$counter_path" 2>/dev/null || true)
        if [ -z "$final_value" ]; then
            test_result_record "FAIL" "EDAC counter disappeared during observation: $counter_path"
            continue
        fi

        delta=$((final_value - baseline_value))
        log_info "[EDAC-FINAL] path=$counter_path value=$final_value delta=$delta"
        if [ "$delta" -lt 0 ]; then
            test_result_record "FAIL" "EDAC counter decreased unexpectedly: $counter_path"
        elif [ "$delta" -gt 0 ]; then
            case "$counter_path" in
                */ue_count)
                    test_result_record "FAIL" "New uncorrectable EDAC errors were reported: path=$counter_path delta=$delta"
                    ;;
                */ce_count)
                    if [ "$STRICT_CE" -eq 1 ]; then
                        test_result_record "FAIL" "New correctable EDAC errors were reported in strict mode: path=$counter_path delta=$delta"
                    else
                        log_warn "New correctable EDAC errors were reported: path=$counter_path delta=$delta"
                    fi
                    ;;
            esac
        fi
    done <"$baseline_file"
fi

edac_dmesg_exclude="No errors|0 errors|0 failures|registered|polling mode|-517|EPROBE_DEFER|deferred probe"
if [ "$STRICT_CE" -eq 0 ]; then
    edac_dmesg_exclude="$edac_dmesg_exclude|correctable|corrected"
fi

scan_dmesg_errors \
    "$SCRIPT_DIR" \
    "EDAC|qcom_llcc_edac|qcom-llcc|llcc" \
    "$edac_dmesg_exclude" || true

grep -Ei '(EDAC|ECC|qcom_llcc_edac|qcom-llcc|llcc).*(fail|error|uncorrectable|UE|corrupt)' \
    "$SCRIPT_DIR/dmesg_snapshot.log" 2>/dev/null |
    grep -Evi "$edac_dmesg_exclude" \
    >"$SCRIPT_DIR/edac_runtime_errors.log" || true

if [ -s "$SCRIPT_DIR/dmesg_errors.log" ] ||
   [ -s "$SCRIPT_DIR/edac_runtime_errors.log" ]; then
    test_result_record "FAIL" "EDAC or LLCC errors were found in the captured kernel log"
fi

test_result_finish
