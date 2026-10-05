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

TESTNAME="Clock_Framework_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

SAMPLE_COUNT=3
SAMPLE_INTERVAL=1
CPUFREQ_TIMEOUT=1800
STDOUT_CLOCK_LIMIT=80
STDOUT_DELTA_LIMIT=100
STDOUT_CONSUMER_LIMIT=100
STDOUT_CPUFREQ_LIMIT=250
PARSE_ERROR=""
CLOCK_CORE_STATUS="SKIP"
SYNC_STATE_STATUS="SKIP"
CPUFREQ_COVERAGE_STATUS="SKIP"
TRANSITION_COUNT=0
VALID_SAMPLE_COUNT=0
FIRST_CLOCK_COUNT=0
FIRST_SUMMARY_FILE=""

usage() {
    cat <<'EOF'
Usage: ./run.sh [OPTIONS]

Validate the complete portable clock workflow: Common Clock Framework state,
clock hierarchy and consumers, sync-state status, and CPUFreq transitions.

Options:
  --samples <count>    Number of clk_summary snapshots, 1-60 (default: 3)
  --interval <seconds> Delay between snapshots, 0-60 (default: 1)
  --cpufreq-timeout <seconds>
                       CPUFreq validation timeout, 60-7200 (default: 1800)
  -h, --help           Show this help and exit
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --samples)
                if [ "$#" -lt 2 ]; then
                    PARSE_ERROR="--samples requires a value"
                    return 1
                fi
                SAMPLE_COUNT="$2"
                shift 2
                ;;
            --interval)
                if [ "$#" -lt 2 ]; then
                    PARSE_ERROR="--interval requires a value"
                    return 1
                fi
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            --cpufreq-timeout)
                if [ "$#" -lt 2 ]; then
                    PARSE_ERROR="--cpufreq-timeout requires a value"
                    return 1
                fi
                CPUFREQ_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                PARSE_ERROR="unknown option: $1"
                return 1
                ;;
        esac
    done

    if ! is_unsigned_number "$SAMPLE_COUNT" ||
       [ "$SAMPLE_COUNT" -lt 1 ] || [ "$SAMPLE_COUNT" -gt 60 ]; then
        PARSE_ERROR="--samples must be an integer from 1 through 60"
        return 1
    fi

    if ! is_unsigned_number "$SAMPLE_INTERVAL" ||
       [ "$SAMPLE_INTERVAL" -gt 60 ]; then
        PARSE_ERROR="--interval must be an integer from 0 through 60"
        return 1
    fi

    if ! is_unsigned_number "$CPUFREQ_TIMEOUT" ||
       [ "$CPUFREQ_TIMEOUT" -lt 60 ] || [ "$CPUFREQ_TIMEOUT" -gt 7200 ]; then
        PARSE_ERROR="--cpufreq-timeout must be an integer from 60 through 7200"
        return 1
    fi

    return 0
}

# Record an interrupted run after restoring any temporary debugfs mount.
handle_signal() {
    hs_signal="$1"
    trap - 0 1 2 15

    if [ -n "${MANAGED_TIMEOUT_CMD_PID:-}" ]; then
        kill "$MANAGED_TIMEOUT_CMD_PID" >/dev/null 2>&1 || true
        wait "$MANAGED_TIMEOUT_CMD_PID" 2>/dev/null || true
        MANAGED_TIMEOUT_CMD_PID=""
    fi

    if ! debugfs_restore; then
        test_result_record \
            "FAIL" \
            "Temporary debugfs mount could not be restored after $hs_signal: $FTEST_DEBUGFS_MOUNTPOINT"
    fi

    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: interrupted by $hs_signal"
}

cd "$SCRIPT_DIR" || exit 1
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! parse_args "$@"; then
    usage >&2
    test_result_finish "FAIL" "$TESTNAME FAIL: invalid command line, $PARSE_ERROR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME testcase"
log_info "Kernel: $(uname -a 2>/dev/null || printf 'unknown')"
log_info "[CLOCK-OP] mode=full-portable-validation samples=$SAMPLE_COUNT interval=${SAMPLE_INTERVAL}s cpufreq_timeout=${CPUFREQ_TIMEOUT}s"

RESULT_DIR="$SCRIPT_DIR/logs_${TESTNAME}_$(date -u +%Y%m%d-%H%M%S)"
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: cannot create evidence directory $RESULT_DIR"
fi
log_info "Evidence directory: $RESULT_DIR"

# shellcheck disable=SC2034  # Consumed by the sourced dependency helper.
CHECK_DEPS_RECOVER=0
# shellcheck disable=SC2034  # Consumed by the sourced dependency helper.
CHECK_DEPS_NO_EXIT=1
if ! check_dependencies \
    awk \
    cat \
    date \
    dirname \
    find \
    mkdir \
    readlink \
    rm \
    sh \
    sleep \
    sort \
    tr \
    uname \
    wc; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: required image-provided base utilities are unavailable"
fi

DT_ROOT=""
DT_PROVIDER_COUNT=0
DT_PROVIDER_FILE="$RESULT_DIR/clock_providers.log"
: >"$DT_PROVIDER_FILE"

log_info "[CLOCK-OP] operation=discover-clock-providers source=runtime-device-tree"
if DT_ROOT=$(dt_runtime_root 2>/dev/null); then
    if dt_list_enabled_property_nodes \
        "$DT_ROOT" \
        "#clock-cells" \
        >"$DT_PROVIDER_FILE"; then
        DT_PROVIDER_COUNT=$(wc -l <"$DT_PROVIDER_FILE" | tr -d '[:space:]')
        log_info "Runtime DT clock providers: $DT_PROVIDER_COUNT"
        log_file_with_label \
            "CLOCK-PROVIDER" \
            "$DT_PROVIDER_FILE" \
            50
    else
        log_info "Runtime device tree exposes no enabled #clock-cells providers"
    fi
else
    log_info "Runtime device tree is unavailable, relying on Common Clock Framework evidence"
fi

log_info "[CLOCK-OP] operation=prepare-debugfs policy=reuse-existing-or-temporary-standard-mount"
CLOCK_DEBUGFS_READY=1
if ! debugfs_prepare; then
    CLOCK_DEBUGFS_READY=0
    if [ "$DT_PROVIDER_COUNT" -gt 0 ]; then
        test_result_record \
            "SKIP" \
            "$DT_PROVIDER_COUNT runtime clock providers were detected but debugfs is unavailable, provide an image with CONFIG_DEBUG_FS and accessible Common Clock Framework diagnostics"
    else
        test_result_record \
            "SKIP" \
            "Neither an accessible debugfs mount nor runtime DT clock-provider evidence is available"
    fi
fi

if [ "$CLOCK_DEBUGFS_READY" -eq 1 ]; then
    CLOCK_SUMMARY_READY=1

trap 'debugfs_restore >/dev/null 2>&1 || true' 0
trap 'handle_signal SIGHUP' 1
trap 'handle_signal SIGINT' 2
trap 'handle_signal SIGTERM' 15

if [ "$FTEST_DEBUGFS_MOUNTED_BY_TEST" = "1" ]; then
    log_info "Mounted debugfs temporarily at $FTEST_DEBUGFS_MOUNTPOINT"
else
    log_info "Using existing debugfs mount: $FTEST_DEBUGFS_MOUNTPOINT"
fi

if ! CLOCK_SUMMARY_PATH=$(
    clock_debugfs_summary_file "$FTEST_DEBUGFS_MOUNTPOINT"
); then
    CLOCK_SUMMARY_READY=0
    if ! debugfs_restore; then
        test_result_record \
            "FAIL" \
            "Temporary debugfs mount could not be restored: $FTEST_DEBUGFS_MOUNTPOINT"
    fi
    trap - 0 1 2 15

    test_result_record \
        "SKIP" \
        "Common Clock Framework clk_summary is not exposed under the discovered debugfs mount, provide an image with CONFIG_COMMON_CLK and CONFIG_DEBUG_FS"
fi

if [ "$CLOCK_SUMMARY_READY" -eq 1 ]; then
    CLOCK_CORE_STATUS="FAIL"
log_info "Common Clock Framework summary: $CLOCK_SUMMARY_PATH"
test_result_record \
    "PASS" \
    "Common Clock Framework clk_summary is readable at $CLOCK_SUMMARY_PATH"

CLOCK_DEBUG_DIR=$(dirname "$CLOCK_SUMMARY_PATH")
for OPTIONAL_NAME in clk_dump clk_orphan_summary clk_orphan_dump; do
    OPTIONAL_PATH="$CLOCK_DEBUG_DIR/$OPTIONAL_NAME"
    OPTIONAL_LOG="$RESULT_DIR/$OPTIONAL_NAME.log"

    if [ ! -r "$OPTIONAL_PATH" ]; then
        log_info "Optional clock diagnostic is unavailable: $OPTIONAL_PATH"
        continue
    fi

    log_info "[CLOCK-OP] operation=read-optional-diagnostic source=$OPTIONAL_PATH"
    run_with_managed_timeout \
        10 \
        "$RESULT_DIR" \
        "clock-$OPTIONAL_NAME" \
        cat "$OPTIONAL_PATH" \
        >"$OPTIONAL_LOG" 2>&1
    OPTIONAL_STATUS=$?

    if [ "$OPTIONAL_STATUS" -eq 0 ]; then
        log_info "Captured optional clock diagnostic: $OPTIONAL_LOG"
    else
        log_warn "Could not capture optional clock diagnostic $OPTIONAL_PATH, rc=$OPTIONAL_STATUS"
    fi
done

TRANSITION_FILE="$RESULT_DIR/clock_transitions.log"
: >"$TRANSITION_FILE"
PREVIOUS_STATE=""
SAMPLE=1
FIRST_SUMMARY_FILE="$RESULT_DIR/clk_summary_001.log"

while [ "$SAMPLE" -le "$SAMPLE_COUNT" ]; do
    SAMPLE_TAG=$(printf '%03d' "$SAMPLE")
    SUMMARY_FILE="$RESULT_DIR/clk_summary_${SAMPLE_TAG}.log"
    STATE_FILE="$RESULT_DIR/clk_state_${SAMPLE_TAG}.log"
    METRICS_FILE="$RESULT_DIR/clk_metrics_${SAMPLE_TAG}.csv"

    log_info "[CLOCK-OP] operation=read-clock-summary sample=$SAMPLE/$SAMPLE_COUNT source=$CLOCK_SUMMARY_PATH destination=$SUMMARY_FILE"
    run_with_managed_timeout \
        10 \
        "$RESULT_DIR" \
        "clock-summary-$SAMPLE_TAG" \
        cat "$CLOCK_SUMMARY_PATH" \
        >"$SUMMARY_FILE" 2>&1
    CAPTURE_STATUS=$?

    if [ "$CAPTURE_STATUS" -ne 0 ]; then
        test_result_record \
            "FAIL" \
            "clk_summary sample $SAMPLE could not be captured within 10 seconds, rc=$CAPTURE_STATUS artifact=$SUMMARY_FILE"
        break
    fi

    if ! clock_summary_analyze \
        "$SUMMARY_FILE" \
        "$STATE_FILE" \
        "$METRICS_FILE"; then
        test_result_record \
            "FAIL" \
            "clk_summary sample $SAMPLE does not contain a recognized non-empty Common Clock Framework table, artifact=$SUMMARY_FILE"
        break
    fi

    CLOCK_COUNT=$(
        awk -F, '$1 == "total_clocks" { print $2; exit }' "$METRICS_FILE"
    )
    ENABLED_COUNT=$(
        awk -F, '$1 == "enabled_clocks" { print $2; exit }' "$METRICS_FILE"
    )
    NONZERO_RATE_COUNT=$(
        awk -F, '$1 == "nonzero_rate_clocks" { print $2; exit }' "$METRICS_FILE"
    )

    if [ "$SAMPLE" -eq 1 ]; then
        FIRST_CLOCK_COUNT="$CLOCK_COUNT"
    fi

    VALID_SAMPLE_COUNT=$((VALID_SAMPLE_COUNT + 1))
    log_info "Clock sample $SAMPLE: total=$CLOCK_COUNT enabled=$ENABLED_COUNT nonzero_rate=$NONZERO_RATE_COUNT"
    log_file_with_label \
        "CLOCK-METRIC:$SAMPLE_TAG" \
        "$METRICS_FILE" \
        0
    log_info "[CLOCK-STATE:$SAMPLE_TAG] columns=name|enable_count|prepare_count|protect_count|rate_hz|hardware_enabled"
    log_file_with_label \
        "CLOCK-STATE:$SAMPLE_TAG" \
        "$STATE_FILE" \
        "$STDOUT_CLOCK_LIMIT"

    if [ -n "$PREVIOUS_STATE" ]; then
        DELTA_FILE="$RESULT_DIR/clk_delta_${SAMPLE_TAG}.log"
        log_info "[CLOCK-OP] operation=compare-clock-state previous=$PREVIOUS_STATE current=$STATE_FILE"
        clock_summary_compare "$PREVIOUS_STATE" "$STATE_FILE" "$DELTA_FILE"
        COMPARE_STATUS=$?

        case "$COMPARE_STATUS" in
            0)
                TRANSITION_COUNT=$((TRANSITION_COUNT + 1))
                {
                    printf 'sample=%s\n' "$SAMPLE"
                    cat "$DELTA_FILE"
                } >>"$TRANSITION_FILE"
                log_file_with_label \
                    "CLOCK-DELTA:$SAMPLE_TAG" \
                    "$DELTA_FILE" \
                    "$STDOUT_DELTA_LIMIT"
                ;;
            1)
                rm -f "$DELTA_FILE"
                ;;
            *)
                test_result_record \
                    "FAIL" \
                    "Clock state comparison failed for sample $SAMPLE"
                break
                ;;
        esac
    fi

    PREVIOUS_STATE="$STATE_FILE"

    if [ "$SAMPLE" -lt "$SAMPLE_COUNT" ] &&
       [ "$SAMPLE_INTERVAL" -gt 0 ]; then
        sleep "$SAMPLE_INTERVAL"
    fi

    SAMPLE=$((SAMPLE + 1))
done

if [ "$VALID_SAMPLE_COUNT" -eq "$SAMPLE_COUNT" ]; then
    CLOCK_CORE_STATUS="PASS"
    test_result_record \
        "PASS" \
        "Validated $VALID_SAMPLE_COUNT clk_summary sample(s), discovered_clocks=$FIRST_CLOCK_COUNT"

    if [ "$SAMPLE_COUNT" -eq 1 ]; then
        test_result_record \
            "SKIP" \
            "Clock transition observation requires at least two samples"
    elif [ "$TRANSITION_COUNT" -gt 0 ]; then
        test_result_record \
            "PASS" \
            "Observed clock state or rate changes across $TRANSITION_COUNT sample interval(s)"
    else
        test_result_record \
            "SKIP" \
            "No clock state or rate transition occurred during the passive ${SAMPLE_COUNT}-sample observation window"
    fi
fi

if [ -r "$FIRST_SUMMARY_FILE" ] && [ "$VALID_SAMPLE_COUNT" -gt 0 ]; then
    TOPOLOGY_FILE="$RESULT_DIR/clock_topology.log"
    TOPOLOGY_METRICS_FILE="$RESULT_DIR/clock_topology_metrics.csv"
    log_info "[CLOCK-OP] operation=validate-clock-hierarchy source=$FIRST_SUMMARY_FILE"

    if clock_summary_topology_analyze \
        "$FIRST_SUMMARY_FILE" \
        "$TOPOLOGY_FILE" \
        "$TOPOLOGY_METRICS_FILE"; then
        ROOT_CLOCK_COUNT=$(awk -F, '$1 == "root_clocks" { print $2; exit }' "$TOPOLOGY_METRICS_FILE")
        PARENT_LINK_COUNT=$(awk -F, '$1 == "parent_links" { print $2; exit }' "$TOPOLOGY_METRICS_FILE")
        test_result_record \
            "PASS" \
            "Validated the runtime clock hierarchy, roots=$ROOT_CLOCK_COUNT parent_links=$PARENT_LINK_COUNT"
        log_file_with_label \
            "CLOCK-TOPOLOGY-METRIC" \
            "$TOPOLOGY_METRICS_FILE" \
            0
    else
        CLOCK_CORE_STATUS="FAIL"
        test_result_record \
            "FAIL" \
            "Runtime clk_summary contains malformed hierarchy, enabled-without-prepare state, hardware-off enabled state, or an enabled child with a disabled parent, artifact=$TOPOLOGY_FILE"
    fi

    CONSUMER_FILE="$RESULT_DIR/clock_consumers.log"
    log_info "[CLOCK-OP] operation=inventory-clock-consumers source=$FIRST_SUMMARY_FILE"
    if clock_summary_consumer_inventory \
        "$FIRST_SUMMARY_FILE" \
        "$CONSUMER_FILE"; then
        CONSUMER_COUNT=$(wc -l <"$CONSUMER_FILE" | tr -d '[:space:]')
        CONSUMER_CLOCK_COUNT=$(awk -F '|' '!seen[$1]++ { count++ } END { print count + 0 }' "$CONSUMER_FILE")
        test_result_record \
            "PASS" \
            "Inventoried $CONSUMER_COUNT registered clock connection(s) across $CONSUMER_CLOCK_COUNT clock(s)"
        log_file_with_label \
            "CLOCK-CONSUMER" \
            "$CONSUMER_FILE" \
            "$STDOUT_CONSUMER_LIMIT"
    else
        test_result_record \
            "SKIP" \
            "The running kernel clk_summary does not expose clock consumer and connection identifiers"
    fi
fi
fi
fi

if [ "$DT_PROVIDER_COUNT" -gt 0 ]; then
    SYNC_STATE_FILE="$RESULT_DIR/clock_sync_state.log"
    SYNC_STATE_METRICS_FILE="$RESULT_DIR/clock_sync_state_metrics.csv"
    log_info "[CLOCK-OP] operation=inventory-sync-state providers=$DT_PROVIDER_COUNT"

    if clock_sync_state_inventory \
        "$DT_PROVIDER_FILE" \
        "$SYNC_STATE_FILE" \
        "$SYNC_STATE_METRICS_FILE"; then
        SYNC_CONSUMER_COUNT=$(awk -F, '$1 == "consumers" { print $2; exit }' "$SYNC_STATE_METRICS_FILE")
        SYNC_DEVICE_COUNT=$(awk -F, '$1 == "platform_devices" { print $2; exit }' "$SYNC_STATE_METRICS_FILE")
        SYNC_UNKNOWN_COUNT=$(awk -F, '$1 == "unknown_consumer_states" { print $2; exit }' "$SYNC_STATE_METRICS_FILE")
        log_file_with_label \
            "CLOCK-SYNC-METRIC" \
            "$SYNC_STATE_METRICS_FILE" \
            0
        log_file_with_label \
            "CLOCK-SYNC-STATE" \
            "$SYNC_STATE_FILE" \
            "$STDOUT_CONSUMER_LIMIT"

        if [ "$SYNC_UNKNOWN_COUNT" -gt 0 ]; then
            SYNC_STATE_STATUS="FAIL"
            test_result_record \
                "FAIL" \
                "$SYNC_UNKNOWN_COUNT exposed clock sync-state consumer status file(s) were empty, artifact=$SYNC_STATE_FILE"
        elif [ "$SYNC_CONSUMER_COUNT" -gt 0 ]; then
            SYNC_STATE_STATUS="PASS"
            test_result_record \
                "PASS" \
                "Validated driver-core clock sync-state data, providers=$DT_PROVIDER_COUNT platform_devices=$SYNC_DEVICE_COUNT consumers=$SYNC_CONSUMER_COUNT"
        else
            SYNC_STATE_STATUS="SKIP"
            test_result_record \
                "SKIP" \
                "$DT_PROVIDER_COUNT runtime clock providers were found, but their platform devices expose no consumer*/status sync-state interface"
        fi
    else
        SYNC_STATE_STATUS="FAIL"
        test_result_record \
            "FAIL" \
            "Runtime clock-provider sync-state inventory could not be generated from $DT_PROVIDER_FILE"
    fi
else
    SYNC_STATE_STATUS="SKIP"
    test_result_record \
        "SKIP" \
        "Runtime device tree exposes no enabled #clock-cells providers for sync-state correlation"
fi

CPUFREQ_ROOT="/sys/devices/system/cpu/cpufreq"
CPUFREQ_POLICY_COUNT=0
for CPUFREQ_POLICY_DIR in "$CPUFREQ_ROOT"/policy*; do
    [ -d "$CPUFREQ_POLICY_DIR" ] || continue
    CPUFREQ_POLICY_COUNT=$((CPUFREQ_POLICY_COUNT + 1))
done

if [ "$CPUFREQ_POLICY_COUNT" -eq 0 ]; then
    CPUFREQ_COVERAGE_STATUS="SKIP"
    test_result_record \
        "SKIP" \
        "No CPUFreq policies are exposed under $CPUFREQ_ROOT, cpufreq_hw functional coverage is not applicable"
else
    CPUFREQ_RUNNER="$SCRIPT_DIR/../CPUFreq_Validation/run.sh"
    CPUFREQ_RESULT="$SCRIPT_DIR/../CPUFreq_Validation/CPUFreq_Validation.res"
    CPUFREQ_LOG="$RESULT_DIR/cpufreq_validation.log"
    CPUFREQ_RESULT_COPY="$RESULT_DIR/CPUFreq_Validation.res"

    if [ ! -r "$CPUFREQ_RUNNER" ]; then
        CPUFREQ_COVERAGE_STATUS="FAIL"
        test_result_record \
            "FAIL" \
            "$CPUFREQ_POLICY_COUNT CPUFreq policies were detected but the focused CPUFreq runner is unavailable at $CPUFREQ_RUNNER"
    else
        rm -f "$CPUFREQ_RESULT"
        log_info "[CLOCK-OP] operation=run-cpufreq-validation policies=$CPUFREQ_POLICY_COUNT timeout=${CPUFREQ_TIMEOUT}s"
        run_with_managed_timeout \
            "$CPUFREQ_TIMEOUT" \
            "$RESULT_DIR" \
            "clock-cpufreq" \
            sh "$CPUFREQ_RUNNER" \
            >"$CPUFREQ_LOG" 2>&1
        CPUFREQ_STATUS=$?
        log_file_with_label \
            "CLOCK-CPUFREQ" \
            "$CPUFREQ_LOG" \
            "$STDOUT_CPUFREQ_LIMIT"

        if [ -r "$CPUFREQ_RESULT" ]; then
            cat "$CPUFREQ_RESULT" >"$CPUFREQ_RESULT_COPY"
            CPUFREQ_RESULT_STATUS=$(awk 'NR == 1 { print $2; exit }' "$CPUFREQ_RESULT")
        else
            CPUFREQ_RESULT_STATUS="missing"
        fi

        if [ "$CPUFREQ_STATUS" -eq 124 ]; then
            CPUFREQ_COVERAGE_STATUS="FAIL"
            test_result_record \
                "FAIL" \
                "CPUFreq validation exceeded the ${CPUFREQ_TIMEOUT}s timeout, artifact=$CPUFREQ_LOG"
        elif [ "$CPUFREQ_STATUS" -ne 0 ]; then
            CPUFREQ_COVERAGE_STATUS="FAIL"
            test_result_record \
                "FAIL" \
                "CPUFreq validation process exited unexpectedly with rc=$CPUFREQ_STATUS, artifact=$CPUFREQ_LOG"
        else
            case "$CPUFREQ_RESULT_STATUS" in
                PASS)
                    CPUFREQ_COVERAGE_STATUS="PASS"
                    test_result_record \
                        "PASS" \
                        "CPUFreq policy, OPP, and all-frequency transition validation passed across $CPUFREQ_POLICY_COUNT policy or policies"
                    ;;
                SKIP)
                    CPUFREQ_COVERAGE_STATUS="SKIP"
                    test_result_record \
                        "SKIP" \
                        "CPUFreq policies were detected but focused functional validation was not applicable, artifact=$CPUFREQ_LOG"
                    ;;
                FAIL)
                    CPUFREQ_COVERAGE_STATUS="FAIL"
                    test_result_record \
                        "FAIL" \
                        "CPUFreq policy, OPP, or frequency transition validation failed, artifact=$CPUFREQ_LOG"
                    ;;
                *)
                    CPUFREQ_COVERAGE_STATUS="FAIL"
                    test_result_record \
                        "FAIL" \
                        "CPUFreq validation did not publish a valid result, status=$CPUFREQ_RESULT_STATUS artifact=$CPUFREQ_LOG"
                    ;;
            esac
        fi
    fi
fi

log_info "[CLOCK-OP] operation=scan-kernel-log modules=clk,clock-controller,qcom-cc,rpmh"
if scan_dmesg_errors \
    "$RESULT_DIR" \
    'clk|clock controller|qcom.*cc|rpmh'; then
    CLOCK_CORE_STATUS="FAIL"
    test_result_record \
        "FAIL" \
        "Clock-related kernel errors were found in $RESULT_DIR/dmesg_errors.log"
elif [ "${DMESG_ACCESS_STATUS:-unknown}" = "unavailable" ]; then
    test_result_record \
        "SKIP" \
        "Kernel log access is unavailable for clock-driver health validation"
else
    test_result_record \
        "PASS" \
        "No non-benign clock-controller errors were found in the captured kernel log"
fi

if ! debugfs_restore; then
    CLOCK_CORE_STATUS="FAIL"
    test_result_record \
        "FAIL" \
        "Temporary debugfs mount could not be restored: $FTEST_DEBUGFS_MOUNTPOINT"
fi
trap - 0 1 2 15

if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ]; then
    COMBINED_STATUS="FAIL"
elif [ "$CLOCK_CORE_STATUS" = "PASS" ] ||
     [ "$SYNC_STATE_STATUS" = "PASS" ] ||
     [ "$CPUFREQ_COVERAGE_STATUS" = "PASS" ]; then
    COMBINED_STATUS="PASS"
else
    COMBINED_STATUS="SKIP"
fi

COVERAGE_FILE="$RESULT_DIR/legacy_workflow_coverage.csv"
{
    printf 'source_workflow,portable_implementation,status,evidence\n'
    printf 'run.sh,combined-orchestration,%s,%s\n' \
        "$COMBINED_STATUS" "$RESULT_DIR"
    printf 'clk_test.sh,clock-state-hierarchy-consumers,%s,%s\n' \
        "$CLOCK_CORE_STATUS" "${FIRST_SUMMARY_FILE:-not-exposed}"
    printf 'sync_state.sh,provider-consumer-status,%s,%s\n' \
        "$SYNC_STATE_STATUS" "${SYNC_STATE_FILE:-$DT_PROVIDER_FILE}"
    printf 'cpufreq_hw_test.sh,policy-opp-all-frequency-transitions,%s,%s\n' \
        "$CPUFREQ_COVERAGE_STATUS" "${CPUFREQ_LOG:-$CPUFREQ_ROOT}"
} >"$COVERAGE_FILE"
log_file_with_label "CLOCK-COVERAGE" "$COVERAGE_FILE" 0

log_info "[CLOCK-RESULT] valid_samples=$VALID_SAMPLE_COUNT requested_samples=$SAMPLE_COUNT changed_intervals=$TRANSITION_COUNT"
test_result_finish "$COMBINED_STATUS"
