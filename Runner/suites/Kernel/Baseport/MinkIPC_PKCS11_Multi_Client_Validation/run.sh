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

TESTNAME="MinkIPC_PKCS11_Multi_Client_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

CLIENT_PATH="${XTEST_QTEE:-}"
TEE_ID="${XTEST_TEE_ID:-}"
CLIENT_COUNT="${XTEST_CLIENT_COUNT:-2}"
TIMEOUT_SECONDS="${XTEST_TIMEOUT:-300}"
BUSY_RETRIES="${XTEST_BUSY_RETRIES:-5}"
SAFE_CASES="1000 1001 1002"
CLIENT_PIDS=""

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
Usage: $0 [OPTIONS]

Run non-mutating QTEE PKCS#11 initialization, discovery, and session cases from
multiple xtest_qtee processes at the same time.

Options:
  --client PATH              xtest_qtee binary or command name
  -d, --tee IDENTIFIER       TEE identifier passed to xtest_qtee
  --clients COUNT            Concurrent clients from 2 through 8, default 2
  --timeout SECONDS          Timeout for each client, default 300
  --busy-retries COUNT       Retries after a QTEE busy response, default 5
  -h, --help                 Show this help
EOF
}

# Purpose: Stop active concurrent clients and restore PKCS#11 runtime state.
# Arguments:
#   None. Uses CLIENT_PIDS populated by this validation.
# Side effects:
#   Terminates active worker processes and restores services started by the test.
# Returns:
#   0 after stopping known clients, waiting for them, and restoring services.
cleanup_multi_clients() {
    for cmc_pid in ${CLIENT_PIDS:-}; do
        if kill -0 "$cmc_pid" 2>/dev/null; then
            kill "$cmc_pid" 2>/dev/null || true
        fi
    done

    for cmc_pid in ${CLIENT_PIDS:-}; do
        wait "$cmc_pid" 2>/dev/null || true
    done

    CLIENT_PIDS=""
    minkipc_pkcs11_restore_runtime
    return 0
}

# Purpose: Identify the retryable QTEE serialization response in client output.
# Arguments:
#   $1 - xtest_qtee output log to inspect.
# Output:
#   None.
# Returns:
#   0 only when a TEEC open-session operation reports the TEEC_ERROR_BUSY
#   result code 0xffff000d. Otherwise 1.
multi_client_log_has_qtee_busy() {
    mclhqb_log="$1"

    [ -r "$mclhqb_log" ] || return 1
    grep -qiE \
        'TEEC[ _-]*open[ _-]*session.*(0x)?ffff000d' \
        "$mclhqb_log"
}

# Purpose: Run one concurrent PKCS#11 client with bounded QTEE busy recovery.
# Arguments:
#   $1 - One-based client index used in log names and retry staggering.
#   $2 - Stable final log-file path for this client.
#   $3 - File where the number of attempts is recorded.
#   $4... - xtest_qtee command and arguments.
# Expected globals:
#   SCRIPT_DIR, TIMEOUT_SECONDS, BUSY_RETRIES, and SAFE_CASES.
# Side effects:
#   Writes one log per attempt, updates the stable final log, and sleeps for a
#   short staggered backoff after a retryable QTEE busy response.
# Returns:
#   0 when an attempt exits successfully and passes manifest validation.
#   1 immediately for a non-busy failure or after busy retries are exhausted.
run_multi_client_worker() {
    rmcw_index="$1"
    rmcw_final_log="$2"
    rmcw_attempt_file="$3"
    shift 3

    rmcw_attempt=1
    rmcw_max_attempts=$((BUSY_RETRIES + 1))

    while [ "$rmcw_attempt" -le "$rmcw_max_attempts" ]; do
        rmcw_attempt_log="$SCRIPT_DIR/xtest_qtee_multiclient_${rmcw_index}_attempt_${rmcw_attempt}.log"
        printf '%s\n' "$rmcw_attempt" > "$rmcw_attempt_file"

        run_with_timeout_log "$TIMEOUT_SECONDS" "$rmcw_attempt_log" "$@"
        rmcw_rc=$?
        cp "$rmcw_attempt_log" "$rmcw_final_log"

        if [ "$rmcw_rc" -eq 0 ] && \
           minkipc_pkcs11_validate_log "$rmcw_attempt_log" "$SAFE_CASES"; then
            return 0
        fi

        if ! multi_client_log_has_qtee_busy "$rmcw_attempt_log"; then
            return 1
        fi

        if [ "$rmcw_attempt" -ge "$rmcw_max_attempts" ]; then
            return 1
        fi

        rmcw_delay=$((1 + ((rmcw_index + rmcw_attempt) % 2)))
        sleep "$rmcw_delay"
        rmcw_attempt=$((rmcw_attempt + 1))
    done

    return 1
}

trap 'cleanup_multi_clients' EXIT

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
        --clients)
            [ "$#" -ge 2 ] || write_early_failure "--clients requires a value"
            CLIENT_COUNT="$2"
            shift 2
            ;;
        --clients=*)
            CLIENT_COUNT=${1#--clients=}
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
        --busy-retries)
            [ "$#" -ge 2 ] || write_early_failure "--busy-retries requires a value"
            BUSY_RETRIES="$2"
            shift 2
            ;;
        --busy-retries=*)
            BUSY_RETRIES=${1#--busy-retries=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            write_early_failure "unknown option: $1"
            ;;
    esac
done

case "$CLIENT_COUNT" in
    ''|*[!0-9]*)
        write_early_failure "invalid client count: $CLIENT_COUNT"
        ;;
esac
if [ "$CLIENT_COUNT" -lt 2 ] || [ "$CLIENT_COUNT" -gt 8 ]; then
    write_early_failure "client count must be between 2 and 8: $CLIENT_COUNT"
fi

case "$TIMEOUT_SECONDS" in
    ''|*[!0-9]*|0)
        write_early_failure "invalid timeout: $TIMEOUT_SECONDS"
        ;;
esac

case "$BUSY_RETRIES" in
    ''|*[!0-9]*)
        write_early_failure "invalid busy retry count: $BUSY_RETRIES"
        ;;
esac
if [ "$BUSY_RETRIES" -gt 10 ]; then
    write_early_failure "busy retry count must be between 0 and 10: $BUSY_RETRIES"
fi

if [ -n "$TEE_ID" ]; then
    case "$TEE_ID" in
        *[!A-Za-z0-9_.:-]*)
            write_early_failure "invalid TEE identifier: $TEE_ID"
            ;;
    esac
fi

rm -f "$RES_FILE"

OS_ID=$(pkg_detect_os_id 2>/dev/null || printf '%s\n' unknown)
log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "OS=$OS_ID arch=$(uname -m 2>/dev/null || printf '%s\n' unknown) clients=$CLIENT_COUNT timeout=${TIMEOUT_SECONDS}s busy_retries=$BUSY_RETRIES"

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

log_info "Launching $CLIENT_COUNT concurrent clients with non-mutating cases: $SAFE_CASES"
log_info "A client is retried only when QTEE reports TEEC_ERROR_BUSY during session open"

STALE_INDEX=1
while [ "$STALE_INDEX" -le 8 ]; do
    rm -f "$SCRIPT_DIR/xtest_qtee_multiclient_${STALE_INDEX}.log"
    rm -f "$SCRIPT_DIR/xtest_qtee_multiclient_${STALE_INDEX}.attempts"
    STALE_ATTEMPT=1
    while [ "$STALE_ATTEMPT" -le 11 ]; do
        rm -f "$SCRIPT_DIR/xtest_qtee_multiclient_${STALE_INDEX}_attempt_${STALE_ATTEMPT}.log"
        STALE_ATTEMPT=$((STALE_ATTEMPT + 1))
    done
    STALE_INDEX=$((STALE_INDEX + 1))
done

CLIENT_INDEX=1
while [ "$CLIENT_INDEX" -le "$CLIENT_COUNT" ]; do
    CLIENT_LOG="$SCRIPT_DIR/xtest_qtee_multiclient_${CLIENT_INDEX}.log"
    CLIENT_ATTEMPTS="$SCRIPT_DIR/xtest_qtee_multiclient_${CLIENT_INDEX}.attempts"
    rm -f "$CLIENT_LOG"

    set -- "$CLIENT_PATH" -t pkcs11
    if [ -n "$TEE_ID" ]; then
        set -- "$@" -d "$TEE_ID"
    fi
    for safe_case in $SAFE_CASES; do
        set -- "$@" "$safe_case"
    done

    run_multi_client_worker \
        "$CLIENT_INDEX" \
        "$CLIENT_LOG" \
        "$CLIENT_ATTEMPTS" \
        "$@" &
    CLIENT_PIDS="$CLIENT_PIDS $!"
    CLIENT_INDEX=$((CLIENT_INDEX + 1))
done

FAILED_CLIENTS=""
CLIENT_INDEX=1
for client_pid in $CLIENT_PIDS; do
    if wait "$client_pid"; then
        CLIENT_RC=0
    else
        CLIENT_RC=$?
    fi

    CLIENT_LOG="$SCRIPT_DIR/xtest_qtee_multiclient_${CLIENT_INDEX}.log"
    CLIENT_ATTEMPTS_FILE="$SCRIPT_DIR/xtest_qtee_multiclient_${CLIENT_INDEX}.attempts"
    CLIENT_ATTEMPTS=$(sed -n '1p' "$CLIENT_ATTEMPTS_FILE" 2>/dev/null)
    case "$CLIENT_ATTEMPTS" in
        ''|*[!0-9]*)
            CLIENT_ATTEMPTS=1
            ;;
    esac

    CLIENT_ATTEMPT=1
    while [ "$CLIENT_ATTEMPT" -le "$CLIENT_ATTEMPTS" ]; do
        CLIENT_ATTEMPT_LOG="$SCRIPT_DIR/xtest_qtee_multiclient_${CLIENT_INDEX}_attempt_${CLIENT_ATTEMPT}.log"
        log_file_with_label "client-$CLIENT_INDEX-attempt-$CLIENT_ATTEMPT" "$CLIENT_ATTEMPT_LOG"
        CLIENT_ATTEMPT=$((CLIENT_ATTEMPT + 1))
    done

    if [ "$CLIENT_RC" -ne 0 ]; then
        if multi_client_log_has_qtee_busy "$CLIENT_LOG"; then
            log_fail "Concurrent client $CLIENT_INDEX exhausted QTEE busy recovery after $CLIENT_ATTEMPTS attempts"
        elif minkipc_pkcs11_validate_log "$CLIENT_LOG" "$SAFE_CASES"; then
            log_fail "Concurrent client $CLIENT_INDEX returned $CLIENT_RC"
        else
            log_fail "Concurrent client $CLIENT_INDEX $MINKIPC_PKCS11_VALIDATION_MESSAGE"
        fi
        FAILED_CLIENTS="$FAILED_CLIENTS $CLIENT_INDEX"
    elif ! minkipc_pkcs11_validate_log "$CLIENT_LOG" "$SAFE_CASES"; then
        log_fail "Concurrent client $CLIENT_INDEX $MINKIPC_PKCS11_VALIDATION_MESSAGE"
        FAILED_CLIENTS="$FAILED_CLIENTS $CLIENT_INDEX"
    else
        log_pass "Concurrent client $CLIENT_INDEX passed after attempts=$CLIENT_ATTEMPTS with cases=$MINKIPC_PKCS11_CASE_TOTAL subtests=$MINKIPC_PKCS11_SUBTEST_TOTAL"
    fi

    CLIENT_INDEX=$((CLIENT_INDEX + 1))
done

CLIENT_PIDS=""

if [ -n "$FAILED_CLIENTS" ]; then
    FAILED_CLIENTS=$(printf '%s\n' "$FAILED_CLIENTS" | sed 's/^[[:space:]]*//')
    finish_test FAIL "concurrent clients failed: $FAILED_CLIENTS" 1
fi

if minkipc_pkcs11_scan_dmesg "$SCRIPT_DIR/pkcs11_multiclient_dmesg"; then
    finish_test FAIL "relevant QCOMTEE or RPMB errors were found in the kernel log" 1
fi

finish_test PASS "clients=$CLIENT_COUNT cases_per_client=3 busy_retries=$BUSY_RETRIES" 0
