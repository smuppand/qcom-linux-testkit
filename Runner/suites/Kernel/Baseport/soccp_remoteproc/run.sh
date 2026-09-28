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

TESTNAME="soccp_remoteproc"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

if ! test_result_init "$TESTNAME" "$RES_FILE"; then
    log_error "Could not initialize the result file: $RES_FILE"
    exit 1
fi

RESULT_ROOT="$SCRIPT_DIR/results/$TESTNAME"
RUN_ID="run-$(date +%Y%m%d-%H%M%S)-$$"
RESULT_DIR="$RESULT_ROOT/$RUN_ID"
DT_NODES_FILE="$RESULT_DIR/soccp_dt_nodes.log"
REMOTEPROC_FILE="$RESULT_DIR/remoteproc_inventory.tsv"
SOCCP_FILE="$RESULT_DIR/soccp_remoteproc.tsv"

# usage
# Prints the supported command-line interface.
usage() {
    cat <<'EOF'
Usage: ./run.sh [options]

Options:
  -h, --help    Show this help.

The suite is read-only. It dynamically validates SOCCP through runtime device
tree, remoteproc sysfs, firmware, driver binding, and kernel-health evidence.
EOF
}

# parse_args <arguments...>
# Accepts help and rejects unsupported arguments. Returns 0 or 2.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

if ! parse_args "$@"; then
    test_result_record \
        "FAIL" \
        "SOCCP remoteproc arguments are invalid, run ./run.sh --help for supported options"
    test_result_finish "FAIL"
fi

if ! mkdir -p "$RESULT_DIR"; then
    test_result_record \
        "FAIL" \
        "Could not create the SOCCP evidence directory: $RESULT_DIR"
    test_result_finish "FAIL"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "SOCCP validation is read-only and uses runtime-discovered target evidence"

soccp_dt_present=0
soccp_runtime_present=0

if discover_soccp_dt_nodes "$DT_NODES_FILE"; then
    soccp_dt_present=1
    while IFS= read -r soccp_dt_node; do
        if [ -z "$soccp_dt_node" ]; then
            continue
        fi
        soccp_dt_compatible=$(
            dt_property_text "$soccp_dt_node" compatible 2>/dev/null ||
                printf '%s\n' unavailable
        )
        soccp_dt_firmware=$(
            dt_property_text "$soccp_dt_node" firmware-name 2>/dev/null ||
                printf '%s\n' unavailable
        )
        log_info "[SOCCP-DT] node=$soccp_dt_node compatible=$soccp_dt_compatible firmware=$soccp_dt_firmware"
    done <"$DT_NODES_FILE"
fi

if discover_soccp_remoteprocs "$REMOTEPROC_FILE" "$SOCCP_FILE"; then
    soccp_runtime_present=1
fi

if [ "$soccp_dt_present" -eq 0 ] && [ "$soccp_runtime_present" -eq 0 ]; then
    test_result_record \
        "SKIP" \
        "SOCCP is not enabled on this target because neither enabled runtime device-tree evidence nor a matching remoteproc instance was discovered"
    test_result_finish "SKIP"
fi

if [ "$soccp_dt_present" -eq 1 ] && [ "$soccp_runtime_present" -eq 0 ]; then
    test_result_record \
        "FAIL" \
        "SOCCP is enabled in the runtime device tree but no matching remoteproc instance is registered, check the SOCCP driver probe and firmware provisioning, artifact=$DT_NODES_FILE"
else
    if [ "$soccp_dt_present" -eq 1 ]; then
        test_result_record \
            "PASS" \
            "SOCCP applicability was confirmed by runtime device-tree and remoteproc evidence"
    else
        test_result_record \
            "SKIP" \
            "SOCCP remoteproc exists but matching identity was not visible in the runtime device tree, continuing with authoritative sysfs evidence"
    fi

    while IFS='|' read -r soccp_path soccp_name soccp_firmware soccp_state; do
        if [ -z "$soccp_path" ]; then
            continue
        fi
        soccp_driver=$(
            remoteproc_driver_name "$soccp_path" 2>/dev/null ||
                printf '%s\n' unbound
        )
        log_info "[SOCCP-RUNTIME] path=$soccp_path name=$soccp_name firmware=$soccp_firmware state=$soccp_state driver=$soccp_driver"

        if [ -z "$soccp_name" ] ||
           [ -z "$soccp_firmware" ] ||
           [ "$soccp_state" = "unknown" ]; then
            test_result_record \
                "FAIL" \
                "SOCCP remoteproc sysfs attributes are incomplete: path=$soccp_path name=${soccp_name:-missing} firmware=${soccp_firmware:-missing} state=$soccp_state"
            continue
        fi

        if [ "$soccp_driver" = "unbound" ]; then
            test_result_record \
                "FAIL" \
                "SOCCP remoteproc is registered without a bound driver: path=$soccp_path"
        else
            test_result_record \
                "PASS" \
                "SOCCP remoteproc driver is bound: path=$soccp_path driver=$soccp_driver"
        fi

        case "$soccp_state" in
            running|suspended|attached)
                test_result_record \
                    "PASS" \
                    "SOCCP remoteproc is ready: name=$soccp_name state=$soccp_state"
                ;;
            offline|detached)
                test_result_record \
                    "FAIL" \
                    "SOCCP remoteproc is present but not ready: name=$soccp_name state=$soccp_state, enable its firmware and boot policy before validation"
                ;;
            crashed)
                test_result_record \
                    "FAIL" \
                    "SOCCP remoteproc is crashed: name=$soccp_name path=$soccp_path, inspect firmware and subsystem-restart evidence"
                ;;
            *)
                test_result_record \
                    "FAIL" \
                    "SOCCP remoteproc exposes an unexpected state: name=$soccp_name state=$soccp_state path=$soccp_path"
                ;;
        esac

        if soccp_firmware_path=$(find_image_firmware "$soccp_firmware"); then
            test_result_record \
                "PASS" \
                "SOCCP firmware is provisioned in an image firmware directory: $soccp_firmware_path"
        else
            test_result_record \
                "SKIP" \
                "SOCCP firmware is not exposed under the standard image firmware directories: firmware=$soccp_firmware, runtime state=$soccp_state confirms the current instance, provision the firmware file for host-managed boot or restart validation"
        fi

        for soccp_attribute in recovery coredump; do
            if [ -r "$soccp_path/$soccp_attribute" ]; then
                soccp_attribute_value=$(
                    sed -n '1p' "$soccp_path/$soccp_attribute" 2>/dev/null ||
                        printf '%s\n' unreadable
                )
                log_info "[SOCCP-ATTRIBUTE] path=$soccp_path/$soccp_attribute value=$soccp_attribute_value"
            else
                log_info "[SOCCP-ATTRIBUTE] optional attribute is not exposed: path=$soccp_path/$soccp_attribute"
            fi
        done
    done <"$SOCCP_FILE"
fi

scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'soccp|soc[-_ ]?cp' \
    'subsys-restart|not a crash|firmware.*already' || true
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record \
        "SKIP" \
        "SOCCP kernel-health validation is unavailable because the target did not expose a readable kernel log, artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ -s "$RESULT_DIR/kernel/dmesg_errors.log" ]; then
    test_result_record \
        "FAIL" \
        "SOCCP kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record \
        "PASS" \
        "No non-benign SOCCP kernel errors were found"
fi

test_result_finish
