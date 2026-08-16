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

TESTNAME="MinkIPC_SMCInvoke_Memory_Object_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
CLIENT_PATH="${SMCINVOKE_CLIENT:-}"
TA_DIR="${SMCINVOKE_TA_DIR:-}"
ITERATIONS="${SMCINVOKE_ITERATIONS:-1}"

usage() {
    echo "Usage: $0 [--client PATH] [--ta-dir DIRECTORY] [--iterations N]"
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
        --ta-dir)
            if [ "$#" -lt 2 ]; then
                log_fail "--ta-dir requires a directory"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            TA_DIR="$2"
            shift 2
            ;;
        --ta-dir=*)
            TA_DIR=${1#--ta-dir=}
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

if [ -z "$TA_DIR" ]; then
    for candidate in \
        /lib/qtee-tas \
        /usr/lib/qtee-tas \
        /data \
        /opt/minkipc-ta
    do
        if [ -r "$candidate/tzecotestapp.mbn" ]; then
            TA_DIR="$candidate"
            break
        fi
    done
fi

if [ -z "$TA_DIR" ] || [ ! -r "$TA_DIR/tzecotestapp.mbn" ]; then
    log_skip "$TESTNAME SKIP: tzecotestapp.mbn is not provisioned"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

OS_ID=$(pkg_detect_os_id 2>/dev/null || echo unknown)
RUN_LOG="$SCRIPT_DIR/smcinvoke_memory_object.log"
rm -f "$RUN_LOG" "$RES_FILE"

log_info "Starting $TESTNAME on OS=$OS_ID"
log_info "Using memory object test TA: $TA_DIR/tzecotestapp.mbn"
log_info "Running memory object validation: $CLIENT_PATH -m $TA_DIR $ITERATIONS"

"$CLIENT_PATH" -m "$TA_DIR" "$ITERATIONS" > "$RUN_LOG" 2>&1
CLIENT_RC=$?

head -n 120 "$RUN_LOG" 2>/dev/null |
while IFS= read -r line; do
    if [ -n "$line" ]; then
        log_info "[smcinvoke_client] $line"
    fi
done

if [ "$CLIENT_RC" -eq 0 ] && grep -Fq "TEST PASSED!" "$RUN_LOG"; then
    log_pass "$TESTNAME PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi

if [ "$CLIENT_RC" -eq 0 ]; then
    log_fail "$TESTNAME FAIL: memory object test did not report TEST PASSED (see $RUN_LOG)"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

log_fail "$TESTNAME FAIL: memory object test returned $CLIENT_RC (see $RUN_LOG)"
echo "$TESTNAME FAIL" > "$RES_FILE"
exit 1
