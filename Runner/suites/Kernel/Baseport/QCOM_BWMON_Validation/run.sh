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
TESTNAME="QCOM_BWMON_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

LOAD_SECONDS="${BWMON_LOAD_SECONDS:-10}"
WORKLOAD_PID=""
WORKLOAD_NAME=""

# usage
# Prints supported command-line options and returns success.
usage() {
    printf '%s\n' "Usage: $0 [--load-seconds N]"
}

# parse_args <arguments...>
# Parses command-line overrides and exits for help or invalid input.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --load-seconds)
                [ "$#" -ge 2 ] || {
                    usage >&2
                    exit 2
                }
                LOAD_SECONDS="$2"
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

# cleanup
# Stops only the optional workload started by this suite. Returns success.
# shellcheck disable=SC2317
cleanup() {
    if [ -n "$WORKLOAD_PID" ] && kill -0 "$WORKLOAD_PID" 2>/dev/null; then
        kill "$WORKLOAD_PID" 2>/dev/null || true
        wait "$WORKLOAD_PID" 2>/dev/null || true
    fi
}

# start_memory_workload
# Starts one bounded image-provided memory workload and sets WORKLOAD_PID and
# WORKLOAD_NAME. Returns 0 when started, otherwise 1.
start_memory_workload() {
    workload_log="$SCRIPT_DIR/bwmon_workload.log"

    if command -v stress-ng >/dev/null 2>&1; then
        stress-ng \
            --vm 1 \
            --vm-bytes 64M \
            --verify \
            --timeout "${LOAD_SECONDS}s" \
            >"$workload_log" 2>&1 &
        WORKLOAD_PID=$!
        WORKLOAD_NAME="stress-ng"
        return 0
    fi

    if command -v stressapptest >/dev/null 2>&1; then
        stressapptest \
            -s "$LOAD_SECONDS" \
            -M 64 \
            -m 1 \
            >"$workload_log" 2>&1 &
        WORKLOAD_PID=$!
        WORKLOAD_NAME="stressapptest"
        return 0
    fi

    if command -v dd >/dev/null 2>&1 && command -v date >/dev/null 2>&1; then
        (
            end_time=$(($(date +%s) + LOAD_SECONDS))
            while [ "$(date +%s)" -lt "$end_time" ]; do
                dd if=/dev/zero of=/dev/null bs=1M count=64 2>/dev/null
            done
        ) >"$workload_log" 2>&1 &
        WORKLOAD_PID=$!
        WORKLOAD_NAME="dd"
        return 0
    fi

    return 1
}

# bwmon_irq_total <needle-file>
# Prints the sum of interrupt counters from lines containing BWMON or a bound
# BWMON device name. Returns 0 even when no matching interrupt label is found.
bwmon_irq_total() {
    needle_file="$1"
    awk -v needles="$needle_file" '
        BEGIN {
            while ((getline line < needles) > 0) {
                wanted[tolower(line)] = 1
            }
            close(needles)
        }
        {
            lower = tolower($0)
            matched = index(lower, "bwmon") > 0
            for (needle in wanted) {
                if (needle != "" && index(lower, needle) > 0) {
                    matched = 1
                }
            }
            if (!matched) {
                next
            }
            for (field = 2; field <= NF; field++) {
                if ($field ~ /^[0-9]+$/) {
                    total += $field
                } else {
                    break
                }
            }
        }
        END {
            print total + 0
        }
    ' /proc/interrupts 2>/dev/null
}

parse_args "$@"

case "$LOAD_SECONDS" in
    ''|*[!0-9]*|0)
        log_fail "--load-seconds must be a positive integer"
        exit 2
        ;;
esac

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

nodes_file="$SCRIPT_DIR/bwmon_nodes.log"
devices_file="$SCRIPT_DIR/bwmon_devices.log"
summary_samples="$SCRIPT_DIR/interconnect_summary_samples.log"
: >"$nodes_file"
: >"$devices_file"
: >"$summary_samples"

trap cleanup 0
trap 'exit 130' 1 2 15

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Configuration: load_seconds=$LOAD_SECONDS"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies awk grep find sort readlink dirname basename tr sed mktemp cat sleep; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

if ! dt_list_compatible_nodes \
    '(^|[[:space:]])qcom,([[:alnum:]_-]+-(cpu|llcc)-bwmon|msm8998-bwmon|sdm845-bwmon)([[:space:]]|$)' regex \
    >"$nodes_file"; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no enabled Qualcomm BWMON node is present in the runtime device tree"
fi

if config_line=$(kernel_config_value CONFIG_QCOM_ICC_BWMON 2>/dev/null); then
    log_info "[BWMON-CONFIG] $config_line"
    case "$config_line" in
        *=y|*=m)
            test_result_record "PASS" "CONFIG_QCOM_ICC_BWMON is enabled"
            ;;
        *)
            test_result_record "FAIL" "CONFIG_QCOM_ICC_BWMON is disabled for applicable BWMON hardware"
            ;;
    esac
else
    log_info "CONFIG_QCOM_ICC_BWMON could not be checked because the running kernel configuration is unavailable"
fi

while IFS= read -r node_dir; do
    [ -n "$node_dir" ] || continue
    compatible=$(dt_property_text "$node_dir" compatible 2>/dev/null || printf '%s\n' unknown)
    log_info "[BWMON-DT] node=$node_dir compatible=$compatible"

    for property_name in reg interconnects interrupts operating-points-v2; do
        if dt_node_has_property "$node_dir" "$property_name"; then
            test_result_record "PASS" "BWMON node exposes required property $property_name"
        else
            test_result_record "FAIL" "BWMON node is missing required property $property_name: $node_dir"
        fi
    done

    if ! device_dir=$(find_platform_device_for_dt_node "$node_dir"); then
        test_result_record "FAIL" "BWMON node has no platform device: $node_dir"
        continue
    fi

    device_name=$(basename "$device_dir")
    printf '%s\n' "$device_name" >>"$devices_file"
    if driver_name=$(platform_device_driver_name "$device_dir"); then
        if [ "$driver_name" = "qcom-bwmon" ]; then
            test_result_record "PASS" "BWMON platform device is bound to qcom-bwmon: $device_name"
        else
            test_result_record "FAIL" "BWMON platform device uses an unexpected driver: device=$device_name driver=$driver_name"
        fi
    else
        test_result_record "FAIL" "BWMON platform device is unbound: $device_name"
    fi
done <"$nodes_file"

irq_before=$(bwmon_irq_total "$devices_file")

if start_memory_workload; then
    test_result_record "PASS" "Started bounded BWMON workload using $WORKLOAD_NAME"

    if debugfs_dir=$(interconnect_debugfs_dir); then
        sample_index=0
        while [ "$sample_index" -lt 3 ]; do
            printf '%s\n' "sample=$sample_index" >>"$summary_samples"
            cat "$debugfs_dir/interconnect_summary" >>"$summary_samples" 2>/dev/null || true
            sleep 1
            sample_index=$((sample_index + 1))
        done
    else
        test_result_record "SKIP" "ICC debugfs summary is unavailable for runtime vote observation"
    fi

    wait "$WORKLOAD_PID"
    workload_rc=$?
    WORKLOAD_PID=""
    if [ "$workload_rc" -eq 0 ]; then
        test_result_record "PASS" "BWMON workload completed successfully"
    else
        test_result_record "FAIL" "BWMON workload failed: tool=$WORKLOAD_NAME status=$workload_rc"
    fi

    irq_after=$(bwmon_irq_total "$devices_file")
    irq_delta=$((irq_after - irq_before))
    if [ "$irq_delta" -gt 0 ]; then
        test_result_record "PASS" "BWMON interrupt counters increased during load: delta=$irq_delta"
    else
        test_result_record "SKIP" "No BWMON interrupt delta was observed, the current OPP may not cross a threshold"
    fi

    if [ -s "$summary_samples" ] && awk '
        $0 !~ /^[[:space:]][[:space:]]/ && NF >= 3 &&
        $(NF - 1) ~ /^[0-9]+$/ && $NF ~ /^[0-9]+$/ &&
        ($(NF - 1) > 0 || $NF > 0) {
            found = 1
        }
        END {
            exit !found
        }
    ' "$summary_samples"; then
        test_result_record "PASS" "ICC summary exposed at least one active bandwidth vote during load"
    elif [ -s "$summary_samples" ]; then
        test_result_record "SKIP" "ICC summary was readable but no non-zero vote was sampled"
    fi
else
    test_result_record "SKIP" "No supported image-provided memory workload is available"
fi

scan_dmesg_errors \
    "$SCRIPT_DIR" \
    "qcom-bwmon|bwmon|interconnect|qnoc" \
    "-517|EPROBE_DEFER|deferred probe|No errors|0 failures" || true

grep -Ei '(qcom-bwmon|bwmon|interconnect|qnoc).*(fail|error|timed out|timeout|unavailable)' \
    "$SCRIPT_DIR/dmesg_snapshot.log" 2>/dev/null |
    grep -Evi -- '-517|EPROBE_DEFER|deferred probe|No errors|0 failures' \
    >"$SCRIPT_DIR/bwmon_runtime_errors.log" || true

if [ -s "$SCRIPT_DIR/dmesg_errors.log" ] ||
   [ -s "$SCRIPT_DIR/bwmon_runtime_errors.log" ]; then
    test_result_record "FAIL" "BWMON or interconnect errors were found in the captured kernel log"
fi

test_result_finish
