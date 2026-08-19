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

TESTNAME="MinkIPC_SMCInvoke_Internal_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
CLIENT_PATH="${SMCINVOKE_CLIENT:-}"
TA_PATH="${SMCINVOKE_INTERNAL_TA:-}"
COMMAND_ID="${SMCINVOKE_INTERNAL_COMMAND:-6}"
ITERATIONS="${SMCINVOKE_ITERATIONS:-1}"
APP_TYPE="${SMCINVOKE_INTERNAL_TYPE:-0}"

usage() {
    echo "Usage: $0 [--client PATH] [--ta PATH] [--command 5|6] [--iterations N] [--type 0|1]"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --client)
            if [ "$#" -lt 2 ]; then
                log_fail "--client requires a path"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            CLIENT_PATH="$2"
            shift 2
            ;;
        --client=*)
            CLIENT_PATH=${1#--client=}
            shift
            ;;
        --ta)
            if [ "$#" -lt 2 ]; then
                log_fail "--ta requires a path"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            TA_PATH="$2"
            shift 2
            ;;
        --ta=*)
            TA_PATH=${1#--ta=}
            shift
            ;;
        --command)
            if [ "$#" -lt 2 ]; then
                log_fail "--command requires a value"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            COMMAND_ID="$2"
            shift 2
            ;;
        --command=*)
            COMMAND_ID=${1#--command=}
            shift
            ;;
        --iterations)
            if [ "$#" -lt 2 ]; then
                log_fail "--iterations requires a value"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            ITERATIONS="$2"
            shift 2
            ;;
        --iterations=*)
            ITERATIONS=${1#--iterations=}
            shift
            ;;
        --type)
            if [ "$#" -lt 2 ]; then
                log_fail "--type requires a value"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            APP_TYPE="$2"
            shift 2
            ;;
        --type=*)
            APP_TYPE=${1#--type=}
            shift
            ;;
        -h|--help)
            usage
            echo "$TESTNAME SKIP" > "$RES_FILE"
            exit 0
            ;;
        *)
            log_fail "Unknown argument: $1"
            usage
            echo "$TESTNAME FAIL" > "$RES_FILE"
            exit 1
            ;;
    esac
done

case "$ITERATIONS" in
    ''|*[!0-9]*|0)
        log_fail "Invalid iteration count: $ITERATIONS"
        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
        ;;
esac

case "$COMMAND_ID" in
    5|6)
        ;;
    14|15|17)
        log_fail "Unsafe internal command $COMMAND_ID is blocked because it can modify RPMB state"
        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
        ;;
    *)
        log_fail "Unsupported internal command: $COMMAND_ID, allowed commands are 5 and 6"
        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
        ;;
esac

case "$APP_TYPE" in
    0|1)
        ;;
    *)
        log_fail "Invalid application type: $APP_TYPE, allowed values are 0 and 1"
        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
        ;;
esac

if ! minkipc_prepare_test_packages; then
    log_fail "$TESTNAME FAIL: MinkIPC package preparation failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if [ -z "$CLIENT_PATH" ]; then
    CLIENT_PATH=$(command -v smcinvoke_client 2>/dev/null || true)
fi

if [ -z "$CLIENT_PATH" ]; then
    for candidate in \
        /usr/bin/smcinvoke_client \
        /usr/sbin/smcinvoke_client \
        /usr/local/bin/smcinvoke_client \
        /usr/lib/minkipc/smcinvoke_client \
        /usr/libexec/minkipc/smcinvoke_client
    do
        if [ -x "$candidate" ]; then
            CLIENT_PATH="$candidate"
            break
        fi
    done
fi

if [ -z "$CLIENT_PATH" ] || [ ! -x "$CLIENT_PATH" ]; then
    log_skip "$TESTNAME SKIP: smcinvoke_client is not installed"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

if [ ! -e /dev/smcinvoke ] && [ ! -e /dev/tee0 ] && [ ! -e /dev/qcomtee ]; then
    log_skip "$TESTNAME SKIP: no SMCInvoke/QCOMTEE device node is present"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

if [ -z "$TA_PATH" ]; then
    for candidate in \
        /lib/qtee-tas/smplap64.mbn \
        /usr/lib/qtee-tas/smplap64.mbn \
        /data/smplap64.mbn \
        /opt/minkipc-ta/smplap64.mbn
    do
        if [ -r "$candidate" ]; then
            TA_PATH="$candidate"
            break
        fi
    done
fi

if [ -z "$TA_PATH" ] || [ ! -r "$TA_PATH" ]; then
    log_skip "$TESTNAME SKIP: smplap64.mbn is not provisioned"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

OS_ID=$(pkg_detect_os_id 2>/dev/null || echo unknown)
RUN_LOG="$SCRIPT_DIR/smcinvoke_internal.log"
rm -f "$RUN_LOG" "$RES_FILE"

case "$COMMAND_ID" in
    5)
        COMMAND_NAME="GPFS"
        ;;
    6)
        COMMAND_NAME="FS"
        ;;
esac

log_info "Starting $TESTNAME on OS=$OS_ID"
log_info "Using internal test TA: $TA_PATH"
log_info "Running internal $COMMAND_NAME validation: $CLIENT_PATH -i $TA_PATH $COMMAND_ID $ITERATIONS $APP_TYPE"

"$CLIENT_PATH" \
    -i \
    "$TA_PATH" \
    "$COMMAND_ID" \
    "$ITERATIONS" \
    "$APP_TYPE" > "$RUN_LOG" 2>&1
CLIENT_RC=$?

head -n 120 "$RUN_LOG" 2>/dev/null |
while IFS= read -r line; do
    if [ -n "$line" ]; then
        log_info "[smcinvoke_client] $line"
    fi
done

SUCCESS_MARKER="TEST SUCCEEDED for $ITERATIONS iterations"

if [ "$CLIENT_RC" -eq 0 ] && grep -Fq "$SUCCESS_MARKER" "$RUN_LOG"; then
    log_pass "$TESTNAME PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi

if [ "$CLIENT_RC" -eq 0 ]; then
    log_fail "$TESTNAME FAIL: internal test did not report $SUCCESS_MARKER (see $RUN_LOG)"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

log_fail "$TESTNAME FAIL: internal test returned $CLIENT_RC (see $RUN_LOG)"
echo "$TESTNAME FAIL" > "$RES_FILE"
exit 1
