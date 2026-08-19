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

TESTNAME="MinkIPC_GPTEEC_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
CLIENT_PATH="${GP_TEST_CLIENT:-}"
GP_TA_PATH="${GP_TA_PATH:-}"

usage() {
    echo "Usage: $0 [--client PATH] [--ta-path DIRECTORY]"
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
        --ta-path)
            if [ "$#" -lt 2 ]; then
                log_fail "--ta-path requires a directory"
                echo "$TESTNAME FAIL" > "$RES_FILE"
                exit 1
            fi
            GP_TA_PATH="$2"
            shift 2
            ;;
        --ta-path=*)
            GP_TA_PATH=${1#--ta-path=}
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

if ! minkipc_prepare_test_packages; then
    log_fail "$TESTNAME FAIL: MinkIPC package preparation failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if [ -z "$CLIENT_PATH" ]; then
    CLIENT_PATH=$(command -v gp_test_client 2>/dev/null || true)
fi
if [ -z "$CLIENT_PATH" ]; then
    for candidate in /usr/bin/gp_test_client /usr/sbin/gp_test_client \
        /usr/local/bin/gp_test_client /usr/lib/minkipc/gp_test_client \
        /usr/libexec/minkipc/gp_test_client; do
        if [ -x "$candidate" ]; then
            CLIENT_PATH="$candidate"
            break
        fi
    done
fi

if [ -z "$CLIENT_PATH" ] || [ ! -x "$CLIENT_PATH" ]; then
    log_skip "$TESTNAME SKIP: gp_test_client is not installed"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

ta_path_complete() {
    tpc_path="$1"
    [ -d "$tpc_path" ] || return 1
    for tpc_ta in example_gpapp_ta32.mbn gpsample.mbn gpsample2.mbn gptest.mbn gptest2.mbn; do
        [ -r "$tpc_path/$tpc_ta" ] || return 1
    done
    return 0
}

if [ -n "$GP_TA_PATH" ] && ! ta_path_complete "$GP_TA_PATH"; then
    log_fail "$TESTNAME FAIL: --ta-path does not contain all five required GP test TAs: $GP_TA_PATH"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

if [ -z "$GP_TA_PATH" ]; then
    for root in /lib/qtee-tas /usr/lib/qtee-tas /data /opt/minkipc-ta; do
        [ -d "$root" ] || continue
        candidate=$(find "$root" -type f -name gptest.mbn 2>/dev/null | sed -n '1p')
        if [ -n "$candidate" ]; then
            candidate=$(dirname "$candidate")
            if ta_path_complete "$candidate"; then
                GP_TA_PATH="$candidate"
                break
            fi
        fi
    done
fi

if [ -z "$GP_TA_PATH" ]; then
    log_skip "$TESTNAME SKIP: GP test TAs are not provisioned"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

if [ ! -e /dev/tee0 ] && [ ! -e /dev/qcomtee ] && [ ! -e /dev/smcinvoke ]; then
    log_skip "$TESTNAME SKIP: no MinkIPC/QCOMTEE device node is present"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

OS_ID=$(pkg_detect_os_id 2>/dev/null || echo unknown)
RUN_LOG="$SCRIPT_DIR/gp_test_client.log"
rm -f "$RUN_LOG" "$RES_FILE"
log_info "Starting $TESTNAME on OS=$OS_ID"
log_info "Pre-loading provisioned TAs with: $CLIENT_PATH -l $GP_TA_PATH"

"$CLIENT_PATH" -l "$GP_TA_PATH" > "$RUN_LOG" 2>&1
CLIENT_RC=$?
head -n 100 "$RUN_LOG" 2>/dev/null | while IFS= read -r line; do
    if [ -n "$line" ]; then
        log_info "[gp_test_client] $line"
    fi
done

if [ "$CLIENT_RC" -eq 0 ]; then
    log_pass "$TESTNAME PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
fi

log_fail "$TESTNAME FAIL: gp_test_client returned $CLIENT_RC (see $RUN_LOG)"
echo "$TESTNAME FAIL" > "$RES_FILE"
exit 1
