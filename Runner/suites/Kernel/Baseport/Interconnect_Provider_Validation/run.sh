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
TESTNAME="Interconnect_Provider_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

# record_config <CONFIG_NAME>
# Records one relevant kernel option. Returns 0 when enabled, 1 when explicitly
# disabled, and 2 when the running kernel configuration is unavailable.
record_config() {
    config_name="$1"
    if config_line=$(kernel_config_value "$config_name" 2>/dev/null); then
        log_info "[ICC-CONFIG] $config_line"
        case "$config_line" in
            *=y|*=m)
                return 0
                ;;
        esac
        return 1
    fi

    log_info "[ICC-CONFIG] $config_name is not visible in the running kernel configuration"
    return 2
}

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
providers_file="$SCRIPT_DIR/icc_provider_nodes.log"
: >"$providers_file"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies find grep sort readlink dirname basename tr awk sed mktemp; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

if ! dt_list_qcom_icc_provider_nodes >"$providers_file"; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no enabled Qualcomm ICC provider is present in the runtime device tree"
fi
if [ ! -s "$providers_file" ]; then
    test_result_finish "FAIL" "$TESTNAME FAIL: ICC provider discovery returned no readable provider list"
fi

for config_name in CONFIG_INTERCONNECT CONFIG_INTERCONNECT_QCOM; do
    record_config "$config_name"
    config_rc=$?
    if [ "$config_rc" -eq 0 ]; then
        test_result_record "PASS" "$config_name is enabled"
    elif [ "$config_rc" -eq 1 ]; then
        test_result_record "FAIL" "$config_name is disabled for applicable ICC hardware"
    else
        test_result_record "SKIP" "$config_name could not be checked because the running kernel configuration is unavailable"
    fi
done

provider_count=0
bound_count=0
synced_count=0
state_missing_count=0

while IFS= read -r node_dir; do
    [ -n "$node_dir" ] || continue
    provider_count=$((provider_count + 1))
    compatible=$(dt_property_text "$node_dir" compatible 2>/dev/null || printf '%s\n' unknown)
    log_info "[ICC-DT] node=$node_dir compatible=$compatible"

    if ! device_dir=$(find_platform_device_for_dt_node "$node_dir"); then
        test_result_record "FAIL" "ICC provider has no platform device: $node_dir"
        continue
    fi

    device_name=$(basename "$device_dir")
    if driver_name=$(platform_device_driver_name "$device_dir"); then
        bound_count=$((bound_count + 1))
        test_result_record "PASS" "ICC provider is bound: device=$device_name driver=$driver_name"
    else
        test_result_record "FAIL" "ICC provider platform device is unbound: $device_name"
        continue
    fi

    if [ -r "$device_dir/state_synced" ]; then
        state_synced=$(tr -d '[:space:]' <"$device_dir/state_synced")
        if [ "$state_synced" = "1" ]; then
            synced_count=$((synced_count + 1))
            test_result_record "PASS" "ICC provider reached synchronized state: $device_name"
        else
            test_result_record "FAIL" "ICC provider did not reach synchronized state: device=$device_name state_synced=${state_synced:-unknown}"
        fi
    else
        state_missing_count=$((state_missing_count + 1))
        test_result_record "SKIP" "state_synced is not exposed for ICC provider $device_name"
    fi
done <"$providers_file"

log_info "ICC provider totals: discovered=$provider_count bound=$bound_count synced=$synced_count state_not_exposed=$state_missing_count"

scan_dmesg_errors \
    "$SCRIPT_DIR" \
    "interconnect|qnoc|icc|bcm_voter" \
    "-517|EPROBE_DEFER|deferred probe|probe deferral|interconnect provider registered|synced state" || true

grep -Ei '(interconnect|qnoc|bcm_voter).*(fail|error|timed out|timeout|unavailable)' \
    "$SCRIPT_DIR/dmesg_snapshot.log" 2>/dev/null |
    grep -Evi -- '-517|EPROBE_DEFER|deferred probe|probe deferral' \
    >"$SCRIPT_DIR/icc_runtime_errors.log" || true

if [ -s "$SCRIPT_DIR/dmesg_errors.log" ] ||
   [ -s "$SCRIPT_DIR/icc_runtime_errors.log" ]; then
    test_result_record "FAIL" "Persistent ICC or NoC errors were found in the captured kernel log"
fi

test_result_finish
