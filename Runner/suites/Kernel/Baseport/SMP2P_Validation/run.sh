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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="SMP2P_Validation"
RES_FILE="./$TESTNAME.res"

# write_result <PASS|FAIL|SKIP>
# Writes the single result line consumed by send-to-lava.sh. Returns the
# status of the write operation.
write_result() {
    result="$1"
    printf '%s %s\n' "$TESTNAME" "$result" >"$RES_FILE"
}

# log_dt_property <node-dir> <property>
# Logs a readable preview and exact hexadecimal bytes for one DT property. It
# never changes the DT and returns 0 when the property was logged, otherwise 1.
log_dt_property() {
    node_dir="$1"
    property="$2"

    if ! property_hex=$(dt_property_hex "$node_dir" "$property"); then
        log_info "[SMP2P-DT] node=$node_dir property=$property value=<absent>"
        return 1
    fi

    property_text=$(dt_property_text "$node_dir" "$property" 2>/dev/null || true)
    if [ -n "$property_text" ]; then
        log_info "[SMP2P-DT] node=$node_dir property=$property text=$property_text raw_hex=$property_hex"
    else
        log_info "[SMP2P-DT] node=$node_dir property=$property raw_hex=$property_hex"
    fi
    return 0
}

failures=0
nodes_file="$SCRIPT_DIR/smp2p_nodes.log"
: >"$nodes_file"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

if ! dt_list_compatible_nodes "qcom,smp2p" >"$nodes_file"; then
    log_skip "$TESTNAME SKIP: no enabled qcom,smp2p node is present at runtime"
    write_result "SKIP"
    exit 0
fi

if ! check_kernel_config "CONFIG_QCOM_SMP2P"; then
    log_fail "CONFIG_QCOM_SMP2P is not enabled for active SMP2P hardware"
    failures=$((failures + 1))
fi

if config_evidence=$(kernel_config_value "CONFIG_QCOM_SMP2P"); then
    log_info "[SMP2P-CONFIG] $config_evidence"
else
    log_info "[SMP2P-CONFIG] CONFIG_QCOM_SMP2P source value is not available"
fi

runtime_smp2p_bound=0
if smp2p_runtime_devices >"$SCRIPT_DIR/smp2p_devices.log"; then
    runtime_smp2p_bound=1
    while IFS= read -r device_name; do
        log_pass "SMP2P platform driver is bound: $device_name"
        device_path=$(readlink -f "/sys/bus/platform/drivers/qcom_smp2p/$device_name" 2>/dev/null || true)
        [ -n "$device_path" ] || device_path="<not resolved>"
        log_info "[SMP2P-DRIVER] device=$device_name sysfs_path=$device_path"
    done <"$SCRIPT_DIR/smp2p_devices.log"
else
    log_fail "No runtime device is bound to the qcom_smp2p platform driver"
    failures=$((failures + 1))
fi

smp2p_irq_registered=0
grep -i "smp2p" /proc/interrupts 2>/dev/null >"$SCRIPT_DIR/smp2p_interrupts.log" || true
if [ -s "$SCRIPT_DIR/smp2p_interrupts.log" ]; then
    smp2p_irq_registered=1
    log_pass "SMP2P interrupt registration is visible in /proc/interrupts"
    while IFS= read -r interrupt_line; do
        log_info "[SMP2P-IRQ] $interrupt_line"
    done <"$SCRIPT_DIR/smp2p_interrupts.log"
else
    log_info "SMP2P interrupt labels are not exposed by this kernel, driver binding is the runtime evidence"
fi

while IFS= read -r node_dir; do
    [ -n "$node_dir" ] || continue
    log_info "SMP2P device-tree node: $node_dir"
    for property in \
        compatible \
        status \
        qcom,smem \
        qcom,local-pid \
        qcom,remote-pid \
        interrupts \
        interrupts-extended \
        mboxes \
        qcom,ipc; do
        log_dt_property "$node_dir" "$property" || true
    done

    if dt_node_has_property "$node_dir" "qcom,smem" && dt_node_has_property "$node_dir" "qcom,local-pid" && dt_node_has_property "$node_dir" "qcom,remote-pid"; then
        log_pass "SMP2P node has SMEM and local and remote PID properties"
    else
        log_fail "SMP2P node is missing required SMEM or PID properties: $node_dir"
        failures=$((failures + 1))
    fi
    if dt_node_has_property "$node_dir" "interrupts" || \
       dt_node_has_property "$node_dir" "interrupts-extended"; then
        log_pass "SMP2P node has interrupt routing"
    elif [ "$runtime_smp2p_bound" -eq 1 ] && [ "$smp2p_irq_registered" -eq 1 ]; then
        log_info "SMP2P node does not expose direct interrupt properties, runtime driver and IRQ evidence validate routing: $node_dir"
    else
        log_fail "SMP2P node has no DT or runtime interrupt-routing evidence: $node_dir"
        failures=$((failures + 1))
    fi

    if dt_node_has_property "$node_dir" "mboxes" || dt_node_has_property "$node_dir" "qcom,ipc"; then
        log_pass "SMP2P node has an outgoing doorbell mechanism"
    else
        log_fail "SMP2P node is missing both mboxes and qcom,ipc: $node_dir"
        failures=$((failures + 1))
    fi

    entry_count=0
    for child_node in "$node_dir"/*; do
        [ -d "$child_node" ] || continue
        dt_node_has_property "$child_node" "qcom,entry-name" || continue
        entry_count=$((entry_count + 1))
        for property in \
            qcom,entry-name \
            interrupt-controller \
            '#interrupt-cells' \
            '#qcom,smem-state-cells'; do
            log_dt_property "$child_node" "$property" || true
        done
        if dt_node_has_property "$child_node" "interrupt-controller" && \
           dt_node_has_property "$child_node" "#interrupt-cells"; then
            log_pass "SMP2P inbound entry is valid: ${child_node##*/}"
        elif dt_node_has_property "$child_node" "#qcom,smem-state-cells"; then
            log_pass "SMP2P outbound entry is valid: ${child_node##*/}"
        else
            log_fail "SMP2P entry has neither inbound nor outbound semantics: ${child_node##*/}"
            failures=$((failures + 1))
        fi
    done
    if [ "$entry_count" -eq 0 ]; then
        log_fail "SMP2P node has no child entries: $node_dir"
        failures=$((failures + 1))
    fi
done <"$nodes_file"

if smp2p_tracepoints_available >"$SCRIPT_DIR/smp2p_tracepoints.log"; then
    while IFS= read -r tracepoint; do
        log_info "Passive SMP2P tracepoint is available: $tracepoint"
    done <"$SCRIPT_DIR/smp2p_tracepoints.log"
else
    log_info "SMP2P tracepoints are not enabled in this kernel configuration"
fi

scan_dmesg_errors "$SCRIPT_DIR" "smp2p|qcom_smp2p|qcom-smem" "not a crash|subsys-restart" || true
if [ -s "$SCRIPT_DIR/dmesg_errors.log" ]; then
    log_fail "SMP2P and SMEM kernel errors are recorded in dmesg_errors.log"
    failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
    log_pass "$TESTNAME PASS"
    write_result "PASS"
else
    log_fail "$TESTNAME FAIL: failures=$failures"
    write_result "FAIL"
fi
exit 0
