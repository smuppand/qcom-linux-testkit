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
TESTNAME="LLCC_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

nodes_file="$SCRIPT_DIR/llcc_nodes.log"
: >"$nodes_file"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies find grep sort readlink dirname basename tr sed mktemp; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

if ! dt_list_compatible_nodes \
    '(^|[[:space:]])qcom,[[:alnum:]_-]+-llcc([[:space:]]|$)' regex \
    >"$nodes_file"; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no enabled Qualcomm LLCC node is present in the runtime device tree"
fi

if config_line=$(kernel_config_value CONFIG_QCOM_LLCC 2>/dev/null); then
    log_info "[LLCC-CONFIG] $config_line"
    case "$config_line" in
        *=y|*=m)
            test_result_record "PASS" "CONFIG_QCOM_LLCC is enabled"
            ;;
        *)
            test_result_record "FAIL" "CONFIG_QCOM_LLCC is disabled for applicable LLCC hardware"
            ;;
    esac
else
    log_info "CONFIG_QCOM_LLCC could not be checked because the running kernel configuration is unavailable"
fi

node_count=0
bound_count=0
while IFS= read -r node_dir; do
    [ -n "$node_dir" ] || continue
    node_count=$((node_count + 1))
    compatible=$(dt_property_text "$node_dir" compatible 2>/dev/null || printf '%s\n' unknown)
    log_info "[LLCC-DT] node=$node_dir compatible=$compatible"

    if ! device_dir=$(find_platform_device_for_dt_node "$node_dir"); then
        test_result_record "FAIL" "LLCC node has no platform device: $node_dir"
        continue
    fi

    device_name=$(basename "$device_dir")
    if driver_name=$(platform_device_driver_name "$device_dir"); then
        bound_count=$((bound_count + 1))
        if [ "$driver_name" = "qcom-llcc" ]; then
            test_result_record "PASS" "LLCC platform device is bound to qcom-llcc: $device_name"
        else
            test_result_record "FAIL" "LLCC platform device is bound to an unexpected driver: device=$device_name driver=$driver_name"
        fi
    else
        test_result_record "FAIL" "LLCC platform device is unbound: $device_name"
    fi
done <"$nodes_file"

log_info "LLCC totals: discovered=$node_count bound=$bound_count"

scan_dmesg_errors \
    "$SCRIPT_DIR" \
    "qcom-llcc|llcc" \
    "EDAC device registered|polling mode|-517|EPROBE_DEFER|deferred probe" || true

grep -Ei '(qcom-llcc|llcc).*(fail|error|timed out|timeout|corrupt)' \
    "$SCRIPT_DIR/dmesg_snapshot.log" 2>/dev/null |
    grep -Evi -- '-517|EPROBE_DEFER|deferred probe|correctable|corrected' \
    >"$SCRIPT_DIR/llcc_runtime_errors.log" || true

if [ -s "$SCRIPT_DIR/dmesg_errors.log" ] ||
   [ -s "$SCRIPT_DIR/llcc_runtime_errors.log" ]; then
    test_result_record "FAIL" "LLCC errors were found in the captured kernel log"
fi

test_result_finish
