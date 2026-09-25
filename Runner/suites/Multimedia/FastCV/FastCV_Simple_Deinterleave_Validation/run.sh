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
. "$TOOLS/lib_pkg_provider.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_fastcv.sh"
TESTNAME="FastCV_Simple_Deinterleave_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

FASTCV_BINARY="${FASTCV_BINARY:-}"
FASTCV_TIMEOUT="${FASTCV_TIMEOUT:-60}"
FASTCV_BINARY_SOURCE="dynamic-discovery"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
RUN_LOG="$RESULT_DIR/fastcv_simple_test.log"
BINARY_REPORT="$RESULT_DIR/fastcv_binary.log"
SUCCESS_MARKER="Results match, Deinterleave Test passed"
FAILURE_MARKER="Results mismatch, Deinterleave Test failed"

if [ -n "$FASTCV_BINARY" ]; then
    FASTCV_BINARY_SOURCE="environment"
fi

# usage
# Print FastCV CLI options and automatic binary-discovery behavior.
# Inputs: none. Output: help text on stdout. Returns: 0. Side effects: none.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --binary PATH      Override the FastCV utility path" \
        "  --timeout SECONDS  Bound the utility runtime, default: 60" \
        "  -h, --help" \
        "Binary selection precedence is CLI, FASTCV_BINARY, then PATH." \
        "The packaged utility validates FastCV data integrity and does not prove CDSP offload."
}

# parse_args ARG...
# Parse CLI overrides into the FastCV binary and timeout globals.
# Inputs: command-line arguments. Output: no stdout.
# Returns: 0 on success, 2 for invalid input, or exits after help.
# Side effects: updates FASTCV_BINARY, FASTCV_BINARY_SOURCE, and FASTCV_TIMEOUT.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --binary)
                [ "$#" -ge 2 ] || return 2
                FASTCV_BINARY="$2"
                if [ -n "$FASTCV_BINARY" ]; then
                    FASTCV_BINARY_SOURCE="cli"
                else
                    FASTCV_BINARY_SOURCE="dynamic-discovery"
                fi
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TIMEOUT="$2"
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

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "FastCV simple deinterleave validation: running fastcv_simple_test64 with bounded execution and exact result-marker checks"
log_info "[FASTCV-POLICY] applicability=dynamic operation=deinterleave-data-integrity timeout=${FASTCV_TIMEOUT}s offload_claim=none"

case "$FASTCV_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record \
            "FAIL" \
            "FastCV configuration is invalid, timeout must be a positive integer"
        test_result_finish
        ;;
esac

fastcv_prepare_runtime_packages
fastcv_package_rc=$?
case "$fastcv_package_rc" in
    0|2)
        ;;
    *)
        test_result_record \
            "FAIL" \
            "FastCV runtime package preparation failed, os=$(pkg_detect_os_id) set=fastcv-runtime"
        test_result_finish
        ;;
esac

FASTCV_BINARY_PATH=""
if [ -n "$FASTCV_BINARY" ]; then
    case "$FASTCV_BINARY" in
        */*)
            FASTCV_BINARY_PATH="$FASTCV_BINARY"
            ;;
        *)
            FASTCV_BINARY_PATH=$(command -v "$FASTCV_BINARY" 2>/dev/null || true)
            ;;
    esac
else
    FASTCV_BINARY_PATH=$(command -v fastcv_simple_test64 2>/dev/null || true)
    if [ -n "$FASTCV_BINARY_PATH" ]; then
        FASTCV_BINARY_SOURCE="path-discovery"
    fi
fi

if [ -z "$FASTCV_BINARY_PATH" ] || [ ! -e "$FASTCV_BINARY_PATH" ]; then
    log_info "[FASTCV-DISCOVERY] selected=none source=$FASTCV_BINARY_SOURCE path_candidate=fastcv_simple_test64"
    case "$FASTCV_BINARY_SOURCE" in
        cli|environment)
            test_result_record \
                "FAIL" \
                "Requested FastCV utility is not present, requested=${FASTCV_BINARY:-empty} source=$FASTCV_BINARY_SOURCE"
            ;;
        *)
            test_result_record \
                "SKIP" \
                "FastCV utility fastcv_simple_test64 is not installed in PATH"
            ;;
    esac
    test_result_finish
fi

if [ ! -f "$FASTCV_BINARY_PATH" ]; then
    log_info "[FASTCV-DISCOVERY] selected=$FASTCV_BINARY_PATH source=$FASTCV_BINARY_SOURCE regular_file=0"
    test_result_record \
        "FAIL" \
        "FastCV utility path is not a regular file, binary=$FASTCV_BINARY_PATH source=$FASTCV_BINARY_SOURCE"
    test_result_finish
fi

if [ ! -x "$FASTCV_BINARY_PATH" ]; then
    log_info "[FASTCV-DISCOVERY] selected=$FASTCV_BINARY_PATH source=$FASTCV_BINARY_SOURCE executable=0"
    test_result_record \
        "FAIL" \
        "FastCV utility exists but is not executable, binary=$FASTCV_BINARY_PATH source=$FASTCV_BINARY_SOURCE"
    test_result_finish
fi

{
    printf 'binary=%s\n' "$FASTCV_BINARY_PATH"
    printf 'source=%s\n' "$FASTCV_BINARY_SOURCE"
    printf 'architecture=%s\n' "$(uname -m 2>/dev/null || printf 'unknown')"
    ls -l "$FASTCV_BINARY_PATH" 2>&1
} >"$BINARY_REPORT"

log_info "[FASTCV-DISCOVERY] selected=$FASTCV_BINARY_PATH source=$FASTCV_BINARY_SOURCE executable=1 artifact=$BINARY_REPORT"
log_file_with_label "FASTCV-BINARY" "$BINARY_REPORT" 10
log_info "[FASTCV-FUNCTIONAL] phase=start binary=$FASTCV_BINARY_PATH timeout=${FASTCV_TIMEOUT}s expected_marker=$SUCCESS_MARKER"

run_with_timeout_log "$FASTCV_TIMEOUT" "$RUN_LOG" "$FASTCV_BINARY_PATH"
fastcv_rc=$?
log_file_with_label "FASTCV-OUTPUT" "$RUN_LOG" 80

success_count=$(grep -F -c "$SUCCESS_MARKER" "$RUN_LOG" 2>/dev/null || true)
failure_count=$(grep -F -c "$FAILURE_MARKER" "$RUN_LOG" 2>/dev/null || true)
module_cli_count=$(grep -E -c '^USAGE: .*test_data_directory' "$RUN_LOG" 2>/dev/null || true)
output_bytes=$(wc -c <"$RUN_LOG" 2>/dev/null | tr -d '[:space:]')

case "$success_count" in
    ''|*[!0-9]*)
        success_count=0
        ;;
esac
case "$failure_count" in
    ''|*[!0-9]*)
        failure_count=0
        ;;
esac
case "$module_cli_count" in
    ''|*[!0-9]*)
        module_cli_count=0
        ;;
esac
case "$output_bytes" in
    ''|*[!0-9]*)
        output_bytes=0
        ;;
esac

log_info "[FASTCV-FUNCTIONAL] phase=complete rc=$fastcv_rc success_markers=$success_count failure_markers=$failure_count module_cli_markers=$module_cli_count output_bytes=$output_bytes artifact=$RUN_LOG"

if [ "$module_cli_count" -gt 0 ]; then
    test_result_record \
        "FAIL" \
        "Selected executable exposes the fastcv_test module CLI instead of the packaged fastcv_simple_test64 deinterleave contract, binary=$FASTCV_BINARY_PATH artifact=$RUN_LOG"
elif [ "$fastcv_rc" -ne 0 ]; then
    test_result_record \
        "FAIL" \
        "FastCV utility failed or exceeded the ${FASTCV_TIMEOUT}s execution bound, rc=$fastcv_rc artifact=$RUN_LOG"
elif [ "$failure_count" -gt 0 ]; then
    test_result_record \
        "FAIL" \
        "FastCV utility reported a deinterleave data mismatch, failure_markers=$failure_count artifact=$RUN_LOG"
elif [ "$success_count" -eq 0 ]; then
    test_result_record \
        "FAIL" \
        "FastCV utility exited successfully but did not report the required deinterleave success marker, artifact=$RUN_LOG"
else
    test_result_record \
        "PASS" \
        "FastCV completed deinterleave data-integrity validation, success_markers=$success_count binary=$FASTCV_BINARY_PATH"
fi

KERNEL_LOG_JOURNAL_FALLBACK=1
export KERNEL_LOG_JOURNAL_FALLBACK
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    "fastrpc|adsprpc|cdsprpc" \
    "not a crash|subsys-restart"
dmesg_rc=$?

if [ "${DMESG_ACCESS_STATUS:-unknown}" != "available" ]; then
    test_result_record \
        "SKIP" \
        "Kernel log access is unavailable for FastCV runtime health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=${DMESG_ACCESS_LOG:-$RESULT_DIR/kernel/dmesg_access.log}"
elif [ "$dmesg_rc" -eq 0 ]; then
    test_result_record \
        "FAIL" \
        "FastRPC-related kernel errors were found during FastCV validation, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record \
        "PASS" \
        "No persistent FastRPC kernel errors were found during FastCV validation"
fi

test_result_finish
