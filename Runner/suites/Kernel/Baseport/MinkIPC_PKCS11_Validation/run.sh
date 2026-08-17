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
# shellcheck disable=SC1090,SC1091
. "$TOOLS/minkipc_pkcs11lib.sh"

TESTNAME="MinkIPC_PKCS11_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

CLIENT_PATH="${XTEST_QTEE:-}"
TEE_ID="${XTEST_TEE_ID:-}"
TEST_LEVEL="${XTEST_LEVEL:-0}"
TIMEOUT_SECONDS="${XTEST_TIMEOUT:-1800}"
ITERATIONS="${XTEST_ITERATIONS:-1}"
CLEAR_STORAGE="${XTEST_CLEAR_STORAGE:-1}"
INCLUDE_TESTS="${XTEST_INCLUDE:-}"
EXCLUDE_TESTS="${XTEST_EXCLUDE:-}"
FILTERED_RUN=0

minkipc_pkcs11_install_cleanup_traps

# Purpose: Print the command-line interface supported by this validation.
# Arguments:
#   None.
# Output:
#   Writes usage text to standard output.
# Returns:
#   0 after writing usage text to standard output.
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [TEST-ID ...]

Run the Qualcomm QTEE PKCS#11 suite through xtest_qtee.

Options:
  --client PATH              xtest_qtee binary or command name
  -d, --tee IDENTIFIER       TEE identifier passed to xtest_qtee
  -l, --level LEVEL          Test level from 0 through 15, default 0
  -t, --suite pkcs11         Accepted for xtest_qtee CLI compatibility
  -x, --exclude TEST-ID      Exclude a test ID, repeatable
  --test TEST-ID             Include a test ID, repeatable
  --timeout SECONDS          Suite timeout, default 1800
  --iterations COUNT         Run count from 1 through 10, default 1
  --clear-storage            Attempt documented pre-run cleanup, default
  --no-clear-storage         Do not run xtest_qtee --clear-storage
  -h, --help                 Show this help

Only the pkcs11 suite is accepted. Test IDs use xtest_qtee substring matching.
The clear-storage applet cleans the upstream storage-test TA namespaces. It is
skipped when either required storage-test TA is not provisioned because it does
not clear the PKCS#11 TA namespace.
EOF
}

# Purpose: Append a validated test filter to a space-separated filter list.
# Arguments:
#   $1 - Existing filter list, which may be empty.
#   $2 - Test ID or filter value to append.
# Output:
#   Prints the updated filter list.
# Returns:
#   0 when the value contains only supported characters, otherwise 1.
append_word() {
    aw_current="$1"
    aw_value="$2"

    case "$aw_value" in
        ''|*[!A-Za-z0-9_.:-]*)
            return 1
            ;;
    esac

    if [ -n "$aw_current" ]; then
        printf '%s %s\n' "$aw_current" "$aw_value"
    else
        printf '%s\n' "$aw_value"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --client)
            [ "$#" -ge 2 ] || write_early_failure "--client requires a value"
            CLIENT_PATH="$2"
            shift 2
            ;;
        --client=*)
            CLIENT_PATH=${1#--client=}
            shift
            ;;
        -d|--tee)
            [ "$#" -ge 2 ] || write_early_failure "$1 requires a value"
            TEE_ID="$2"
            shift 2
            ;;
        --tee=*)
            TEE_ID=${1#--tee=}
            shift
            ;;
        -l|--level)
            [ "$#" -ge 2 ] || write_early_failure "$1 requires a value"
            TEST_LEVEL="$2"
            shift 2
            ;;
        --level=*)
            TEST_LEVEL=${1#--level=}
            shift
            ;;
        -t|--suite)
            [ "$#" -ge 2 ] || write_early_failure "$1 requires a value"
            if [ "$2" != "pkcs11" ]; then
                write_early_failure "only the pkcs11 suite is supported, requested=$2"
            fi
            shift 2
            ;;
        --suite=*)
            if [ "${1#--suite=}" != "pkcs11" ]; then
                write_early_failure "only the pkcs11 suite is supported, requested=${1#--suite=}"
            fi
            shift
            ;;
        -x|--exclude)
            [ "$#" -ge 2 ] || write_early_failure "$1 requires a value"
            EXCLUDE_TESTS=$(append_word "$EXCLUDE_TESTS" "$2") || \
                write_early_failure "invalid excluded test ID: $2"
            FILTERED_RUN=1
            shift 2
            ;;
        --exclude=*)
            exclude_value=${1#--exclude=}
            EXCLUDE_TESTS=$(append_word "$EXCLUDE_TESTS" "$exclude_value") || \
                write_early_failure "invalid excluded test ID: $exclude_value"
            FILTERED_RUN=1
            shift
            ;;
        --test)
            [ "$#" -ge 2 ] || write_early_failure "--test requires a value"
            INCLUDE_TESTS=$(append_word "$INCLUDE_TESTS" "$2") || \
                write_early_failure "invalid included test ID: $2"
            FILTERED_RUN=1
            shift 2
            ;;
        --test=*)
            include_value=${1#--test=}
            INCLUDE_TESTS=$(append_word "$INCLUDE_TESTS" "$include_value") || \
                write_early_failure "invalid included test ID: $include_value"
            FILTERED_RUN=1
            shift
            ;;
        --timeout)
            [ "$#" -ge 2 ] || write_early_failure "--timeout requires a value"
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --timeout=*)
            TIMEOUT_SECONDS=${1#--timeout=}
            shift
            ;;
        --iterations)
            [ "$#" -ge 2 ] || write_early_failure "--iterations requires a value"
            ITERATIONS="$2"
            shift 2
            ;;
        --iterations=*)
            ITERATIONS=${1#--iterations=}
            shift
            ;;
        --clear-storage)
            CLEAR_STORAGE=1
            shift
            ;;
        --no-clear-storage)
            CLEAR_STORAGE=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                INCLUDE_TESTS=$(append_word "$INCLUDE_TESTS" "$1") || \
                    write_early_failure "invalid included test ID: $1"
                FILTERED_RUN=1
                shift
            done
            ;;
        -*)
            write_early_failure "unknown option: $1"
            ;;
        *)
            INCLUDE_TESTS=$(append_word "$INCLUDE_TESTS" "$1") || \
                write_early_failure "invalid included test ID: $1"
            FILTERED_RUN=1
            shift
            ;;
    esac
done

case "$TEST_LEVEL" in
    ''|*[!0-9]*)
        write_early_failure "invalid level: $TEST_LEVEL"
        ;;
esac
if [ "$TEST_LEVEL" -gt 15 ]; then
    write_early_failure "level must be between 0 and 15: $TEST_LEVEL"
fi

case "$TIMEOUT_SECONDS" in
    ''|*[!0-9]*|0)
        write_early_failure "invalid timeout: $TIMEOUT_SECONDS"
        ;;
esac

case "$ITERATIONS" in
    ''|*[!0-9]*|0)
        write_early_failure "invalid iteration count: $ITERATIONS"
        ;;
esac
if [ "$ITERATIONS" -gt 10 ]; then
    write_early_failure "iteration count must be between 1 and 10: $ITERATIONS"
fi

case "$CLEAR_STORAGE" in
    0|1)
        ;;
    *)
        write_early_failure "XTEST_CLEAR_STORAGE must be 0 or 1: $CLEAR_STORAGE"
        ;;
esac

if [ -n "$TEE_ID" ]; then
    case "$TEE_ID" in
        *[!A-Za-z0-9_.:-]*)
            write_early_failure "invalid TEE identifier: $TEE_ID"
            ;;
    esac
fi

for configured_test in $INCLUDE_TESTS $EXCLUDE_TESTS; do
    case "$configured_test" in
        ''|*[!A-Za-z0-9_.:-]*)
            write_early_failure "invalid test filter from environment: $configured_test"
            ;;
    esac
done

if [ -n "${XTEST_INCLUDE:-}" ] || [ -n "${XTEST_EXCLUDE:-}" ]; then
    FILTERED_RUN=1
fi

rm -f "$RES_FILE"

OS_ID=$(pkg_detect_os_id 2>/dev/null || printf '%s\n' unknown)

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "OS=$OS_ID arch=$(uname -m 2>/dev/null || printf '%s\n' unknown) level=$TEST_LEVEL iterations=$ITERATIONS timeout=${TIMEOUT_SECONDS}s"

if ! minkipc_pkcs11_prepare_runtime "$CLIENT_PATH" "$OS_ID"; then
    case "$MINKIPC_PKCS11_PREP_RESULT" in
        SKIP)
            finish_test SKIP "$MINKIPC_PKCS11_PREP_MESSAGE" 0
            ;;
        *)
            finish_test FAIL "$MINKIPC_PKCS11_PREP_MESSAGE" 1
            ;;
    esac
fi
CLIENT_PATH="$MINKIPC_PKCS11_CLIENT_PATH"

CLEAR_LOG="$SCRIPT_DIR/xtest_qtee_clear_storage.log"
rm -f "$CLEAR_LOG" "$SCRIPT_DIR/xtest_qtee_pkcs11.log"
STALE_ITERATION=1
while [ "$STALE_ITERATION" -le 10 ]; do
    rm -f "$SCRIPT_DIR/xtest_qtee_pkcs11_iteration_${STALE_ITERATION}.log"
    STALE_ITERATION=$((STALE_ITERATION + 1))
done

if [ "$CLEAR_STORAGE" -eq 1 ]; then
    MISSING_STORAGE_TAS=$(minkipc_pkcs11_missing_clear_storage_tas)
    if [ -n "$MISSING_STORAGE_TAS" ]; then
        MISSING_STORAGE_TAS=$(printf '%s\n' "$MISSING_STORAGE_TAS" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        log_info "Skipping xtest_qtee --clear-storage because required upstream storage-test TAs are not provisioned: $MISSING_STORAGE_TAS"
        log_info "The PKCS#11 suite initializes its test token and removes its own test objects"
    else
        log_info "Running documented pre-test cleanup: $CLIENT_PATH --clear-storage"
        run_with_timeout_log 300 "$CLEAR_LOG" "$CLIENT_PATH" --clear-storage
        CLEAR_RC=$?
        log_file_with_label clear-storage "$CLEAR_LOG"

        if [ "$CLEAR_RC" -eq 0 ]; then
            log_pass "xtest_qtee pre-test storage cleanup completed"
        else
            log_warn "xtest_qtee --clear-storage returned $CLEAR_RC despite both storage-test TAs being present"
            log_info "Continuing because this applet does not clear the PKCS#11 TA namespace"
        fi
    fi
else
    log_info "Pre-test storage cleanup was disabled by request"
fi

set -- "$CLIENT_PATH" -t pkcs11 -l "$TEST_LEVEL"
if [ -n "$TEE_ID" ]; then
    set -- "$@" -d "$TEE_ID"
fi
for excluded_test in $EXCLUDE_TESTS; do
    set -- "$@" -x "$excluded_test"
done
for included_test in $INCLUDE_TESTS; do
    set -- "$@" "$included_test"
done

log_info "Running QTEE PKCS#11 validation with level=$TEST_LEVEL"
if [ -n "$TEE_ID" ]; then
    log_info "Using TEE identifier: $TEE_ID"
fi
if [ -n "$INCLUDE_TESTS" ]; then
    log_info "Included test filters: $INCLUDE_TESTS"
fi
if [ -n "$EXCLUDE_TESTS" ]; then
    log_info "Excluded test filters: $EXCLUDE_TESTS"
fi

EXPECTED_CASES="$MINKIPC_PKCS11_EXPECTED_CASES"
if [ "$FILTERED_RUN" -eq 1 ]; then
    EXPECTED_CASES="-"
fi

TOTAL_CASES=0
TOTAL_SUBTESTS=0
ITERATION=1
while [ "$ITERATION" -le "$ITERATIONS" ]; do
    if [ "$ITERATIONS" -eq 1 ]; then
        RUN_LOG="$SCRIPT_DIR/xtest_qtee_pkcs11.log"
        RUN_LABEL="xtest_qtee"
    else
        RUN_LOG="$SCRIPT_DIR/xtest_qtee_pkcs11_iteration_${ITERATION}.log"
        RUN_LABEL="xtest_qtee-$ITERATION"
    fi

    log_info "Running QTEE PKCS#11 validation iteration $ITERATION of $ITERATIONS"
    run_with_timeout_log "$TIMEOUT_SECONDS" "$RUN_LOG" "$@"
    RUN_RC=$?
    log_file_with_label "$RUN_LABEL" "$RUN_LOG"

    if [ "$RUN_RC" -ne 0 ]; then
        if grep -qiE 'rpmb|storage|token.*not|TEE_ERROR|TEEC_' "$RUN_LOG"; then
            log_info "Failure may indicate missing RPMB provisioning, persistent storage, or PKCS#11 TA access"
        fi
        finish_test FAIL "iteration $ITERATION returned $RUN_RC, see $RUN_LOG" 1
    fi

    if ! minkipc_pkcs11_validate_log "$RUN_LOG" "$EXPECTED_CASES"; then
        finish_test FAIL "iteration $ITERATION $MINKIPC_PKCS11_VALIDATION_MESSAGE, see $RUN_LOG" 1
    fi

    log_pass "PKCS#11 iteration $ITERATION passed with cases=$MINKIPC_PKCS11_CASE_TOTAL subtests=$MINKIPC_PKCS11_SUBTEST_TOTAL"
    TOTAL_CASES=$((TOTAL_CASES + MINKIPC_PKCS11_CASE_TOTAL))
    TOTAL_SUBTESTS=$((TOTAL_SUBTESTS + MINKIPC_PKCS11_SUBTEST_TOTAL))
    ITERATION=$((ITERATION + 1))
done

if minkipc_pkcs11_scan_dmesg "$SCRIPT_DIR/pkcs11_dmesg"; then
    finish_test FAIL "relevant QCOMTEE or RPMB errors were found in the kernel log" 1
fi

finish_test PASS "iterations=$ITERATIONS cases=$TOTAL_CASES subtests=$TOTAL_SUBTESTS level=$TEST_LEVEL" 0
