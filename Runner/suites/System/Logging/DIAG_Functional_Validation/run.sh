#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# DIAG userspace infrastructure and diag_mdlog functional validation.

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TESTNAME="DIAG_Functional_Validation"
RES_FILE="./$TESTNAME.res"

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
    echo "$TESTNAME FAIL" >"$RES_FILE" 2>/dev/null || true
    exit 1
fi

REPO_ROOT="$(dirname "$INIT_ENV")"

if [ -z "${INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

# --------- DIAG helper library ---------
DIAG_LIB=""

if [ -n "${TOOLS:-}" ] && [ -f "$TOOLS/lib_diag.sh" ]; then
    DIAG_LIB="$TOOLS/lib_diag.sh"
elif [ -n "${ROOT_DIR:-}" ] && [ -f "$ROOT_DIR/utils/lib_diag.sh" ]; then
    DIAG_LIB="$ROOT_DIR/utils/lib_diag.sh"
elif [ -n "${REPO_ROOT:-}" ] && [ -f "$REPO_ROOT/utils/lib_diag.sh" ]; then
    DIAG_LIB="$REPO_ROOT/utils/lib_diag.sh"
else
    log_error "Missing DIAG helper library"
    log_error "Checked ${TOOLS:-<TOOLS unset>}/lib_diag.sh"
    log_error "Checked ${ROOT_DIR:-<ROOT_DIR unset>}/utils/lib_diag.sh"
    log_error "Checked ${REPO_ROOT:-<REPO_ROOT unset>}/utils/lib_diag.sh"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

# shellcheck source=../../../../utils/lib_diag.sh
# shellcheck disable=SC1091
. "$DIAG_LIB"

test_path="$(find_test_case_by_name "$TESTNAME")"

if [ -n "$test_path" ]; then
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

# --------- Configuration defaults ---------
DIAG_DURATION_SECS="${DIAG_DURATION_SECS:-10}"
DIAG_NRT_DURATION_SECS="${DIAG_NRT_DURATION_SECS:-5}"
DIAG_STARTUP_TIMEOUT_SECS="${DIAG_STARTUP_TIMEOUT_SECS:-15}"
DIAG_STOP_TIMEOUT_SECS="${DIAG_STOP_TIMEOUT_SECS:-5}"
DIAG_FILE_SIZE="${DIAG_FILE_SIZE:-20}"
DIAG_FILE_COUNT="${DIAG_FILE_COUNT:-2}"
DIAG_TEST_NONREALTIME="${DIAG_TEST_NONREALTIME:-1}"
DIAG_KEEP_ARTIFACTS="${DIAG_KEEP_ARTIFACTS:-1}"
DIAG_PROBE_OPTIONAL_HELP="${DIAG_PROBE_OPTIONAL_HELP:-0}"
DIAG_ARTIFACT_DIR="${DIAG_ARTIFACT_DIR:-./diag_artifacts}"
DIAG_MASK_FILE="${DIAG_MASK_FILE:-}"
DIAG_MASK_LIST="${DIAG_MASK_LIST:-}"
DIAG_PERIPHERAL_MASK="${DIAG_PERIPHERAL_MASK:-}"
DIAG_PROCESSOR_MASK="${DIAG_PROCESSOR_MASK:-}"
DIAG_USERPD_MASK="${DIAG_USERPD_MASK:-}"
DIAG_QDSS_MASK="${DIAG_QDSS_MASK:-}"
DIAG_TX_MODE="${DIAG_TX_MODE:-}"
DIAG_BUFFER_PERIPHERAL_MASK="${DIAG_BUFFER_PERIPHERAL_MASK:-}"
DIAG_ETR_BUFFER_SIZE="${DIAG_ETR_BUFFER_SIZE:-}"
DIAG_QMDL2_V2="${DIAG_QMDL2_V2:-0}"

print_usage() {
    cat <<EOF_USAGE
Usage: $0 [options]

Options:
  --duration <seconds> Normal diag_mdlog observation time. Default: 10
  --nrt-duration <seconds> Non-real-time observation time. Default: 5
  --file-size <value> Value passed to diag_mdlog -s. Default: 20
  --file-count <count> Value passed to diag_mdlog -n. Default: 2
  --mask-file <path> Mask file passed through diag_mdlog -f
  --mask-list <path> Mask-list file passed through diag_mdlog -l
  --peripheral-mask <mask> Peripheral mask passed through diag_mdlog -p
  --no-nonrealtime Do not validate diag_mdlog -b
  --help Show this help text

Environment-only platform options:
  DIAG_PROCESSOR_MASK
  DIAG_USERPD_MASK
  DIAG_QDSS_MASK
  DIAG_TX_MODE
  DIAG_BUFFER_PERIPHERAL_MASK
  DIAG_ETR_BUFFER_SIZE
  DIAG_QMDL2_V2=0|1
  DIAG_ARTIFACT_DIR
  DIAG_KEEP_ARTIFACTS=0|1
  DIAG_PROBE_OPTIONAL_HELP=0|1
EOF_USAGE
}

require_option_value() {
    if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        log_error "Missing value for ${1:-option}"
        print_usage
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
}

# --------- Argument parsing ---------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --duration)
            require_option_value "$@"
            shift
            DIAG_DURATION_SECS="$1"
            ;;
        --nrt-duration)
            require_option_value "$@"
            shift
            DIAG_NRT_DURATION_SECS="$1"
            ;;
        --file-size)
            require_option_value "$@"
            shift
            DIAG_FILE_SIZE="$1"
            ;;
        --file-count)
            require_option_value "$@"
            shift
            DIAG_FILE_COUNT="$1"
            ;;
        --mask-file)
            require_option_value "$@"
            shift
            DIAG_MASK_FILE="$1"
            ;;
        --mask-list)
            require_option_value "$@"
            shift
            DIAG_MASK_LIST="$1"
            ;;
        --peripheral-mask)
            require_option_value "$@"
            shift
            DIAG_PERIPHERAL_MASK="$1"
            ;;
        --no-nonrealtime)
            DIAG_TEST_NONREALTIME=0
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            print_usage
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 1
            ;;
    esac

    shift
done

# --------- Artifact setup ---------
mkdir -p "$DIAG_ARTIFACT_DIR" || {
    log_fail "$TESTNAME FAIL: unable to create artifact directory $DIAG_ARTIFACT_DIR"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
}

DIAG_ARTIFACT_DIR="$(
    cd "$DIAG_ARTIFACT_DIR" || exit 1
    pwd
)"

DIAG_RUN_DIR="$DIAG_ARTIFACT_DIR/run_$$"

mkdir -p "$DIAG_RUN_DIR" || {
    log_fail "$TESTNAME FAIL: unable to create run directory $DIAG_RUN_DIR"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
}

chmod 0777 "$DIAG_ARTIFACT_DIR" "$DIAG_RUN_DIR" 2>/dev/null || true

DIAG_RESULT_TABLE="$DIAG_RUN_DIR/results.tsv"
: >"$DIAG_RESULT_TABLE"

trap 'diag_cleanup_owned_processes' EXIT
trap 'diag_cleanup_owned_processes; exit 130' HUP INT TERM

log_info "--------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase --------------------------"
log_info "Using DIAG helper library: $DIAG_LIB"
log_info "Artifacts: $DIAG_RUN_DIR"
log_info "Configuration: duration=${DIAG_DURATION_SECS}s nrt_duration=${DIAG_NRT_DURATION_SECS}s file_size=$DIAG_FILE_SIZE file_count=$DIAG_FILE_COUNT nonrealtime=$DIAG_TEST_NONREALTIME optional_help=$DIAG_PROBE_OPTIONAL_HELP"

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform
fi

log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='$(uname -r 2>/dev/null || echo unknown)' arch='$(uname -m 2>/dev/null || echo unknown)'"

# --------- Dependency validation ---------
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies \
    awk \
    sed \
    grep \
    find \
    wc \
    tail \
    tr \
    chmod \
    mkdir \
    date \
    head \
    basename \
    cat \
    rm \
    sleep \
    uname \
    dirname; then

    log_skip "$TESTNAME SKIP: missing base runtime dependencies"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --------- DIAG capability inventory ---------
if ! diag_inventory_tools; then
    diag_print_summary
    log_skip "$TESTNAME SKIP: diag_mdlog is not available"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# --------- Router and socket validation ---------
diag_validate_router_socket

# --------- Requested configuration validation ---------
if ! diag_validate_requested_configuration; then
    diag_print_summary
    log_fail "$TESTNAME FAIL: invalid DIAG configuration"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

# --------- DIAG session validation ---------
DIAG_CORE_STATUS="SKIP"
DIAG_OWNED_NORMAL_VALIDATED=0

if diag_validate_existing_mdlog_session; then
    DIAG_CORE_STATUS="PASS"
else
    if diag_validate_normal_session; then
        if diag_has_validated_session; then
            DIAG_CORE_STATUS="PASS"
            DIAG_OWNED_NORMAL_VALIDATED=1
        fi
    else
        if diag_has_session_conflict; then
            log_warn "An external diag_mdlog session became active while starting the owned session"

            if diag_validate_existing_mdlog_session; then
                DIAG_CORE_STATUS="PASS"
            fi
        fi
    fi

    if [ "$DIAG_OWNED_NORMAL_VALIDATED" -eq 1 ]; then
        diag_validate_nonrealtime_session || true
    elif ! diag_has_session_conflict; then
        diag_record_result \
            "Non-real-time session" \
            "SKIP" \
            "normal owned session was not validated"
    fi
fi

# --------- Final result ---------
DIAG_OVERALL_RESULT="$(
    diag_compute_overall_result "$DIAG_CORE_STATUS"
)"

diag_print_summary
log_info "DIAG artifacts retained at: $DIAG_RUN_DIR"

case "$DIAG_OVERALL_RESULT" in
    PASS)
        log_pass "$TESTNAME PASS"
        echo "$TESTNAME PASS" >"$RES_FILE"
        ;;
    FAIL)
        log_fail "$TESTNAME FAIL"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        ;;
    *)
        log_skip "$TESTNAME SKIP"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        ;;
esac

if [ "$DIAG_KEEP_ARTIFACTS" = "0" ]; then
    log_info "Removing DIAG artifacts because DIAG_KEEP_ARTIFACTS=0"
    rm -rf "$DIAG_RUN_DIR"
fi

exit 0
