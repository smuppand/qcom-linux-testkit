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
. "$TOOLS/lib_qrtr.sh"
TESTNAME="QRTR_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

QRTR_TIMEOUT="${QRTR_TIMEOUT:-10}"
QRTR_EXPECT_SERVICES="${QRTR_EXPECT_SERVICES:-}"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
RAW_TOPOLOGY="$RESULT_DIR/qrtr_lookup.log"
NORMALIZED_TOPOLOGY="$RESULT_DIR/qrtr_topology.tsv"
TOPOLOGY_SUMMARY="$RESULT_DIR/qrtr_summary.env"
EXPECTED_REPORT="$RESULT_DIR/expected_services.tsv"

# usage
# Prints the CLI syntax and option descriptions. Inputs: none. Output: help text
# on stdout. Returns: 0. Side effects: none.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --timeout SECONDS" \
        "  --expect-services LIST" \
        "      Optional target/job policy, not required for automatic discovery" \
        "      Comma-separated decimal service[:version[:instance]] selectors" \
        "  -h, --help" \
        "CLI options override environment variables."
}

# parse_args <arguments...>
# Applies CLI overrides to the QRTR configuration globals. Inputs: shell
# arguments accepted by usage(). Output: help text only for --help. Returns: 0
# on success or 2 for a missing option value or unknown option. Side effects:
# updates QRTR_TIMEOUT and QRTR_EXPECT_SERVICES, and exits 0 for --help.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout)
                [ "$#" -ge 2 ] || return 2
                QRTR_TIMEOUT="$2"
                shift 2
                ;;
            --expect-services)
                [ "$#" -ge 2 ] || return 2
                QRTR_EXPECT_SERVICES="$2"
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
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "QRTR validation: capturing the live service topology and validating endpoint structure, uniqueness, and requested services"
log_info "Configuration: timeout=${QRTR_TIMEOUT}s expected_services=${QRTR_EXPECT_SERVICES:-none}"
if [ -n "$QRTR_EXPECT_SERVICES" ]; then
    log_info "[QRTR-POLICY] mode=explicit expected_services=$QRTR_EXPECT_SERVICES source=CLI-or-environment"
else
    log_info "[QRTR-POLICY] mode=dynamic expected_services=none action=validate-all-live-services"
fi

case "$QRTR_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "QRTR configuration is invalid, timeout must be a positive integer"
        test_result_finish
        ;;
esac

qrtr_log_runtime_evidence
qrtr_capture_topology "$RAW_TOPOLOGY" "$QRTR_TIMEOUT"
capture_rc=$?
case "$capture_rc" in
    0)
        log_info "[QRTR-DISCOVERY] runtime=present lookup=completed provider=$QRTR_LOOKUP_PROVIDER command=$QRTR_LOOKUP_COMMAND artifact=$RAW_TOPOLOGY"
        ;;
    2)
        if qrtr_runtime_present; then
            test_result_record "SKIP" "QRTR runtime is present but neither native qrtr-lookup nor the bundled Python AF_QIPCRTR provider is runnable"
        else
            test_result_record "SKIP" "QRTR runtime evidence is absent on this target"
        fi
        test_result_finish
        ;;
    *)
        test_result_record "FAIL" "QRTR topology query failed or returned an invalid header, rc=$capture_rc artifact=$RAW_TOPOLOGY"
        test_result_finish
        ;;
esac

if qrtr_analyze_topology \
    "$RAW_TOPOLOGY" \
    "$NORMALIZED_TOPOLOGY" \
    "$TOPOLOGY_SUMMARY"; then
    log_info "[QRTR-FUNCTIONAL] operation=control-lookup provider=$QRTR_LOOKUP_PROVIDER command=$QRTR_LOOKUP_COMMAND response_rows=$QRTR_TOPOLOGY_ROW_COUNT status=verified"
    test_result_record "PASS" "QRTR completed a control-port service lookup through $QRTR_LOOKUP_PROVIDER and returned $QRTR_TOPOLOGY_ROW_COUNT validated response row(s)"
    log_info "[QRTR-TOPOLOGY] rows=$QRTR_TOPOLOGY_ROW_COUNT services=$QRTR_TOPOLOGY_SERVICE_COUNT nodes=$QRTR_TOPOLOGY_NODE_COUNT normalized=$NORMALIZED_TOPOLOGY"
    qrtr_log_topology "$NORMALIZED_TOPOLOGY" 64 "QRTR-SERVICE"
    test_result_record "PASS" "QRTR topology is structurally valid with $QRTR_TOPOLOGY_SERVICE_COUNT service tuple(s) across $QRTR_TOPOLOGY_NODE_COUNT node(s)"
else
    log_file_with_label "QRTR-RAW" "$RAW_TOPOLOGY" 25
    test_result_record "FAIL" "QRTR topology is malformed, reason=${QRTR_TOPOLOGY_FAILURE_REASON:-unknown} raw=$RAW_TOPOLOGY summary=$TOPOLOGY_SUMMARY"
fi

if [ -n "$QRTR_EXPECT_SERVICES" ] && [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ]; then
    if qrtr_validate_expected_services \
        "$RAW_TOPOLOGY" \
        "$QRTR_EXPECT_SERVICES" \
        "$EXPECTED_REPORT"; then
        log_file_with_label "QRTR-EXPECTED" "$EXPECTED_REPORT" 32
        test_result_record "PASS" "All $QRTR_EXPECTED_SERVICE_COUNT requested QRTR service selector(s) are advertised, artifact=$EXPECTED_REPORT"
    else
        expected_rc=$?
        log_file_with_label "QRTR-EXPECTED" "$EXPECTED_REPORT" 32
        if [ "$expected_rc" -eq 3 ]; then
            test_result_record "FAIL" "QRTR expected-service configuration is invalid, reason=$QRTR_EXPECTED_FAILURE_REASON"
        else
            test_result_record "FAIL" "$QRTR_MISSING_SERVICE_COUNT of $QRTR_EXPECTED_SERVICE_COUNT requested QRTR service selector(s) are missing, artifact=$EXPECTED_REPORT"
        fi
    fi
fi

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'qrtr|qcom_glink|glink|rpmsg' \
    'endpoint is not connected'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for QRTR health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "QRTR-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "QRTR-related kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent QRTR-related kernel errors were found"
fi

test_result_finish
