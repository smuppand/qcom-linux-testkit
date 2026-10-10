#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Read-only QPS615 PCIe Ethernet interface readiness validation.

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
# shellcheck disable=SC1091
. "$TOOLS/lib_system.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_ethernet.sh"

TESTNAME="QPS615_Interface_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

PREPARE_OVERLAY=0
SHOW_HELP=0
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
QPS_RUNTIME_DIR="$RESULT_DIR/qps615_runtime"
AVAILABLE_INTERFACES="$RESULT_DIR/qps615_interfaces.log"

# usage
#   Print the command-line contract. stdout: usage text. return: 0.
#   Side effects: none.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --prepare-overlay  Select VendorDtbOverlays=staging for the next FIT boot" \
        "  -h, --help" \
        "The default validation is read-only. Overlay preparation never reboots the target."
}

# parse_args <arguments...>
#   Parse suite options into PREPARE_OVERLAY and SHOW_HELP. stdout: none.
#   return: 0 on success or 2 for invalid input. Side effects: updates globals.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --prepare-overlay)
                PREPARE_OVERLAY=1
                shift
                ;;
            -h|--help)
                SHOW_HELP=1
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

if ! test_result_init "$TESTNAME" "$RES_FILE"; then
    log_error "Could not initialize the result file: $RES_FILE"
    exit 1
fi

if ! parse_args "$@"; then
    usage >&2
    test_result_record "FAIL" "QPS615 interface command-line configuration is invalid"
    test_result_finish "FAIL"
fi

if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
fi

if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies \
    awk \
    basename \
    date \
    find \
    grep \
    mkdir \
    readlink \
    sed \
    tr \
    uname \
    wc; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: image-provided base utilities required for QPS615 discovery are unavailable"
fi

if ! mkdir -p "$RESULT_DIR"; then
    test_result_record "FAIL" "Could not create QPS615 evidence directory $RESULT_DIR"
    test_result_finish "FAIL"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "Configuration: prepare_overlay=$PREPARE_OVERLAY fit_value=$QPS615_OVERLAY_VALUE applicability=runtime-dt-or-pci"

if [ "$PREPARE_OVERLAY" -eq 1 ]; then
    trap 'efi_restore_efivarfs_ro >>"$QPS_RUNTIME_DIR/qps615_efi_cleanup.log" 2>&1' EXIT
    trap '
        test_result_record "FAIL" "QPS615 overlay preparation interrupted by SIGHUP"
        test_result_finish "FAIL"
    ' HUP
    trap '
        test_result_record "FAIL" "QPS615 overlay preparation interrupted by SIGINT"
        test_result_finish "FAIL"
    ' INT
    trap '
        test_result_record "FAIL" "QPS615 overlay preparation interrupted by SIGTERM"
        test_result_finish "FAIL"
    ' TERM
    ethv_qps615_prepare_overlay "$QPS_RUNTIME_DIR"
    prepare_status=$?
    case "$prepare_status" in
        0)
            log_info "QPS615 FIT overlay value is already selected in EFI"
            ;;
        4)
            test_result_record "SKIP" "$QPS615_OVERLAY_REASON"
            test_result_finish \
                "SKIP" \
                "$TESTNAME SKIP: QPS615 FIT selection was updated, reboot manually and rerun with --prepare-overlay"
            ;;
        2)
            test_result_record \
                "FAIL" \
                "QPS615 FIT overlay preparation was explicitly requested but is unavailable: ${QPS615_OVERLAY_REASON:-unknown reason}"
            test_result_finish "FAIL"
            ;;
        *)
            test_result_record \
                "FAIL" \
                "QPS615 FIT overlay preparation failed: ${QPS615_OVERLAY_REASON:-unknown reason}"
            test_result_finish "FAIL"
            ;;
    esac
else
    ethv_qps615_collect_overlay_state "$QPS_RUNTIME_DIR" || true
fi

ethv_qps615_collect_runtime "$QPS_RUNTIME_DIR"
qps_runtime_status=$?

case "${QPS615_OVERLAY_STATE:-unavailable}" in
    configured)
        test_result_record \
            "PASS" \
            "QPS615 FIT value is selected in EFI: $QPS615_OVERLAY_VARIABLE=$QPS615_OVERLAY_VALUE"
        ;;
    absent|value-mismatch)
        if [ "$qps_runtime_status" -eq 2 ]; then
            test_result_record \
                "SKIP" \
                "EFI FIT selection does not enable QPS615: $QPS615_OVERLAY_REASON, use --prepare-overlay only on a QPS615 FIT target"
        else
            test_result_record \
                "SKIP" \
                "QPS615 runtime hardware is active without the staging EFI value, the current image may use a base DT or another boot integration"
        fi
        ;;
    *)
        test_result_record \
            "SKIP" \
            "QPS615 EFI FIT selection could not be inspected: ${QPS615_OVERLAY_REASON:-EFI tooling unavailable}"
        ;;
esac

if [ "${QPS615_DT_NODE_COUNT:-0}" -gt 0 ]; then
    test_result_record \
        "PASS" \
        "Found $QPS615_DT_NODE_COUNT enabled runtime DT node(s) compatible with pci1179,0623"
else
    test_result_record \
        "SKIP" \
        "No enabled QPS615 runtime DT node was found, legacy PCI-only discovery remains supported"
fi

if [ "${QPS615_PWRCTRL_EXPECTED_COUNT:-0}" -gt 0 ] && \
   [ "${QPS615_PWRCTRL_BOUND_COUNT:-0}" -eq "$QPS615_PWRCTRL_EXPECTED_COUNT" ]; then
    test_result_record \
        "PASS" \
        "All $QPS615_PWRCTRL_BOUND_COUNT supply-backed QPS615 DT node(s) are bound to pwrctrl-tc9563"
elif [ "${QPS615_PWRCTRL_EXPECTED_COUNT:-0}" -eq 0 ]; then
    test_result_record \
        "SKIP" \
        "No QPS615 DT node declares the supply-backed pwrctrl-tc9563 contract"
elif [ -n "${QPS615_PWRCTRL_FAILURE_REASON:-}" ]; then
    test_result_record \
        "FAIL" \
        "$QPS615_PWRCTRL_FAILURE_REASON"
fi

case "$qps_runtime_status" in
    0)
        test_result_record \
            "PASS" \
            "QPS615 topology, firmware, driver, and netdev readiness are healthy: $QPS615_READINESS_SUMMARY"
        ;;
    1)
        test_result_record \
            "FAIL" \
            "QPS615 interface readiness failed: ${QPS615_FAILURE_REASON:-unknown runtime failure}"
        ;;
    2)
        if [ "$PREPARE_OVERLAY" -eq 1 ] && \
           [ "${QPS615_OVERLAY_STATE:-unavailable}" = "configured" ]; then
            test_result_record \
                "FAIL" \
                "QPS615 FIT value is selected in EFI but no enabled pci1179,0623 DT node or switch 1179:0623 is active, reboot if the value was just selected or inspect the FIT image and boot firmware"
            test_result_finish "FAIL"
        fi
        test_result_finish \
            "SKIP" \
            "$TESTNAME SKIP: no enabled QPS615 DT node or enumerated switch 1179:0623 was discovered, FIT targets can opt in with --prepare-overlay"
        ;;
    3)
        test_result_record "FAIL" "QPS615 runtime discovery received an invalid path or result directory"
        test_result_finish "FAIL"
        ;;
    *)
        test_result_record "FAIL" "QPS615 runtime discovery returned unexpected status $qps_runtime_status"
        test_result_finish "FAIL"
        ;;
esac

log_file_with_label "QPS615-RUNTIME" "$QPS_RUNTIME_DIR/qps615_runtime.tsv" 60

if [ -n "${QPS615_ETHERNET_SKIP_REASON:-}" ] && \
   [ "$qps_runtime_status" -eq 0 ]; then
    test_result_record "SKIP" "$QPS615_ETHERNET_SKIP_REASON"
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: QPS615 is present but no Ethernet port is provisioned by the runtime device tree"
fi

if ! ethv_qps615_list_netdevs \
    "$QPS_RUNTIME_DIR/qps615_runtime.tsv" >"$AVAILABLE_INTERFACES"; then
    test_result_record \
        "FAIL" \
        "Could not parse QPS615 netdev correlation from $QPS_RUNTIME_DIR/qps615_runtime.tsv"
    test_result_finish "FAIL"
fi

available_count=$(wc -l <"$AVAILABLE_INTERFACES" | tr -d '[:space:]')
log_file_with_label "QPS615-INTERFACE" "$AVAILABLE_INTERFACES" 16

if [ "$available_count" -eq 0 ]; then
    if [ "$qps_runtime_status" -eq 1 ]; then
        test_result_finish "FAIL"
    fi
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: QPS615 is present but no runtime-provisioned Ethernet netdev was discovered"
fi

while IFS= read -r qps_iface; do
    [ -n "$qps_iface" ] || continue
    qps_driver=$(ethv_get_driver "$qps_iface")
    qps_module=$(ethv_get_driver_module "$qps_iface")
    qps_bus=$(ethv_get_bus_info "$qps_iface")
    qps_carrier=$(ethv_get_carrier "$qps_iface")
    qps_operstate=$(ethv_get_operstate "$qps_iface")
    qps_speed=$(ethv_get_speed "$qps_iface")
    qps_duplex=$(ethv_get_duplex "$qps_iface")
    qps_ipv4=$(ethv_get_ipv4 "$qps_iface")

    log_info "[QPS615-INTERFACE] interface=$qps_iface driver=${qps_driver:-unknown} module=${qps_module:-built-in-or-unexposed} bus=${qps_bus:-unknown} carrier=$qps_carrier operstate=$qps_operstate speed=${qps_speed:-unknown} duplex=${qps_duplex:-unknown} ipv4=${qps_ipv4:-none}"

    if [ ! -d "/sys/class/net/$qps_iface" ]; then
        test_result_record "FAIL" "QPS615 interface $qps_iface disappeared during validation"
        continue
    fi

    case "$qps_driver" in
        tc956x*)
            test_result_record \
                "PASS" \
                "QPS615 interface $qps_iface is dynamically correlated and bound to $qps_driver"
            ;;
        *)
            test_result_record \
                "FAIL" \
                "QPS615 interface $qps_iface is not bound to a TC956x driver, observed=${qps_driver:-unbound}"
            ;;
    esac

    if [ "$qps_carrier" = "1" ]; then
        test_result_record "PASS" "QPS615 interface $qps_iface reports link carrier"
    else
        test_result_record \
            "SKIP" \
            "QPS615 interface $qps_iface has no carrier, connect an external peer before traffic validation"
    fi

    if ethv_valid_ipv4 "$qps_ipv4"; then
        test_result_record "PASS" "QPS615 interface $qps_iface has configured IPv4 address $qps_ipv4"
    else
        test_result_record \
            "SKIP" \
            "QPS615 interface $qps_iface has no configured IPv4 address, configure the lab network before traffic validation"
    fi

    if command -v ethtool >/dev/null 2>&1; then
        qps_ethtool_driver_log="$RESULT_DIR/${qps_iface}_ethtool_driver.log"
        qps_ethtool_link_log="$RESULT_DIR/${qps_iface}_ethtool_link.log"
        if ethtool -i "$qps_iface" >"$qps_ethtool_driver_log" 2>&1 &&
           ethtool "$qps_iface" >"$qps_ethtool_link_log" 2>&1; then
            log_file_with_label "QPS615-ETHTOOL-DRIVER-$qps_iface" "$qps_ethtool_driver_log" 30
            log_file_with_label "QPS615-ETHTOOL-LINK-$qps_iface" "$qps_ethtool_link_log" 50
            test_result_record \
                "PASS" \
                "QPS615 interface $qps_iface supports ethtool driver and link inspection"
        else
            test_result_record \
                "FAIL" \
                "Image-provided ethtool could not inspect QPS615 interface $qps_iface, see $qps_ethtool_driver_log and $qps_ethtool_link_log"
        fi
    else
        test_result_record \
            "SKIP" \
            "ethtool is not image-provided, QPS615 sysfs readiness was validated without optional ethtool diagnostics"
    fi
done <"$AVAILABLE_INTERFACES"

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'tc956|qps615' \
    'Link is Down|Link down|carrier lost|no carrier|deferred probe|EPROBE_DEFER'
qps_dmesg_status=$?

if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record \
        "SKIP" \
        "Kernel log access is unavailable for QPS615 readiness validation, artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$qps_dmesg_status" -eq 0 ]; then
    log_file_with_label "QPS615-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 30
    test_result_record \
        "FAIL" \
        "QPS615 or TC956x probe errors were found in $RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No non-benign QPS615 or TC956x errors were found in the captured kernel log"
fi

test_result_finish
