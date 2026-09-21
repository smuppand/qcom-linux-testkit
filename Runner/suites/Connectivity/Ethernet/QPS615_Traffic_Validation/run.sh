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
# shellcheck disable=SC1091
. "$TOOLS/lib_ethernet.sh"
TESTNAME="QPS615_Traffic_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

QPS615_TRAFFIC_FIXTURE="${QPS615_TRAFFIC_FIXTURE:-0}"
QPS615_INTERFACES="${QPS615_INTERFACES:-}"
QPS615_PEER="${QPS615_PEER:-}"
QPS615_PING_COUNT="${QPS615_PING_COUNT:-10}"
QPS615_PING_WAIT="${QPS615_PING_WAIT:-2}"
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
QPS_RUNTIME_DIR="$RESULT_DIR/qps615_runtime"
AVAILABLE_INTERFACES="$RESULT_DIR/qps615_interfaces.log"
SELECTED_INTERFACES="$RESULT_DIR/selected_interfaces.log"
QPS_TRAFFIC_PASS_COUNT=0

# usage
# Takes no arguments, prints the CLI contract to stdout, returns 0, and has no
# side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --fixture [0|1]   Confirm reachable external Ethernet peers" \
        "  --interfaces LIST Override unique automatic QPS615 netdev selection" \
        "      Comma-separated QPS615 netdevs, or all" \
        "  --peer IPV4       Override interface-specific default-gateway discovery" \
        "  --ping-count COUNT, default: 10" \
        "  --ping-wait SECONDS, default: 2" \
        "  -h, --help" \
        "QPS615 topology and eligible netdevs are discovered dynamically." \
        "CLI options override environment variables."
}

# parse_args <arguments...>
# Parses CLI options into QPS615_* globals without producing stdout. Returns 0
# on success or 2 for an unknown option or missing value and has no other side
# effects.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fixture)
                if [ "$#" -ge 2 ]; then
                    case "$2" in
                        0|1)
                            QPS615_TRAFFIC_FIXTURE="$2"
                            shift 2
                            continue
                            ;;
                    esac
                fi
                QPS615_TRAFFIC_FIXTURE=1
                shift
                ;;
            --interfaces)
                ethv_require_option_value "$1" "$#" || return 2
                QPS615_INTERFACES="$2"
                shift 2
                ;;
            --peer)
                ethv_require_option_value "$1" "$#" || return 2
                QPS615_PEER="$2"
                shift 2
                ;;
            --ping-count)
                ethv_require_option_value "$1" "$#" || return 2
                QPS615_PING_COUNT="$2"
                shift 2
                ;;
            --ping-wait)
                ethv_require_option_value "$1" "$#" || return 2
                QPS615_PING_WAIT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                return 2
                ;;
        esac
    done
}

parse_args "$@" || {
    usage >&2
    exit 2
}

test_result_init "$TESTNAME" "$RES_FILE"
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "QPS615 traffic validation: correlating switch netdevs, fixture selection, packet transfer, and error-counter deltas"
log_info "Configuration: fixture=$QPS615_TRAFFIC_FIXTURE interfaces=${QPS615_INTERFACES:-auto-unique} peer=${QPS615_PEER:-auto-gateway} ping_count=$QPS615_PING_COUNT ping_wait=${QPS615_PING_WAIT}s"
log_info "[QPS615-POLICY] topology=dynamic interface_policy=${QPS615_INTERFACES:-auto-unique} peer_policy=${QPS615_PEER:-auto-gateway} fixture_opt_in=$QPS615_TRAFFIC_FIXTURE"

if ! ethv_is_boolean "$QPS615_TRAFFIC_FIXTURE" ||
   ! ethv_is_positive_integer "$QPS615_PING_COUNT" ||
   ! ethv_is_positive_integer "$QPS615_PING_WAIT"; then
    test_result_record "FAIL" "QPS615 fixture, ping count, or ping wait configuration is invalid"
    test_result_finish
fi
if [ -n "$QPS615_PEER" ]; then
    if ! ethv_valid_unicast_ipv4 "$QPS615_PEER"; then
        test_result_record "FAIL" "QPS615 peer must be a usable unicast IPv4 address, observed=$QPS615_PEER"
        test_result_finish
    fi
fi

ethv_qps615_collect_runtime "$QPS_RUNTIME_DIR"
qps_runtime_rc=$?
case "$qps_runtime_rc" in
    0)
        log_file_with_label "QPS615-RUNTIME" "$QPS_RUNTIME_DIR/qps615_runtime.tsv" 40
        ;;
    2)
        test_result_record "SKIP" "QPS615 runtime hardware is not present or no Ethernet port is provisioned"
        test_result_finish
        ;;
    *)
        log_file_with_label "QPS615-RUNTIME" "$QPS_RUNTIME_DIR/qps615_runtime.tsv" 40
        test_result_record "FAIL" "QPS615 runtime topology is unhealthy, reason=${QPS615_FAILURE_REASON:-unknown} artifact=$QPS_RUNTIME_DIR/qps615_runtime.tsv"
        test_result_finish
        ;;
esac

if ! ethv_qps615_list_netdevs \
    "$QPS_RUNTIME_DIR/qps615_runtime.tsv" >"$AVAILABLE_INTERFACES"; then
    test_result_record "FAIL" "QPS615 netdev correlation could not be parsed from $QPS_RUNTIME_DIR/qps615_runtime.tsv"
    test_result_finish
fi
available_count=$(wc -l <"$AVAILABLE_INTERFACES" | tr -d '[:space:]')
log_file_with_label "QPS615-AVAILABLE-INTERFACE" "$AVAILABLE_INTERFACES" 16
if [ "$available_count" -eq 0 ]; then
    test_result_record "SKIP" "QPS615 is present but exposes no traffic-capable netdev"
    test_result_finish
fi

if [ "$QPS615_TRAFFIC_FIXTURE" != "1" ]; then
    test_result_record "SKIP" "QPS615 traffic fixture was not confirmed, use --fixture only when the selected ports have reachable peers"
    test_result_finish
fi

if ! command -v ping >/dev/null 2>&1; then
    test_result_record "SKIP" "QPS615 traffic fixture was selected but ping is not image-provided"
    test_result_finish
fi
if ! command -v ip >/dev/null 2>&1 &&
   ! command -v ifconfig >/dev/null 2>&1; then
    test_result_record "SKIP" "QPS615 traffic fixture was selected but neither ip nor ifconfig is image-provided for IPv4 discovery"
    test_result_finish
fi
if [ -z "$QPS615_PEER" ] && ! command -v ip >/dev/null 2>&1; then
    test_result_record "SKIP" "QPS615 automatic gateway discovery requires the image-provided ip command, or provide --peer"
    test_result_finish
fi

: >"$SELECTED_INTERFACES"
case "$QPS615_INTERFACES" in
    "")
        if [ "$available_count" -ne 1 ]; then
            test_result_record "SKIP" "QPS615 exposes $available_count netdevs, select fixture-connected ports with --interfaces"
            test_result_finish
        fi
        sed -n '1p' "$AVAILABLE_INTERFACES" >"$SELECTED_INTERFACES"
        selection_source="auto-unique"
        ;;
    all)
        cp "$AVAILABLE_INTERFACES" "$SELECTED_INTERFACES"
        selection_source="explicit-all"
        ;;
    *)
        case "$QPS615_INTERFACES" in
            ,*|*,|*,,*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:,-]*)
                test_result_record "FAIL" "QPS615 interface selection is malformed: $QPS615_INTERFACES"
                test_result_finish
                ;;
        esac
        printf '%s\n' "$QPS615_INTERFACES" \
            | tr ',' '\n' \
            | sort -u >"$SELECTED_INTERFACES"
        selection_source="explicit-list"
        ;;
esac
log_info "[QPS615-SELECTION] source=$selection_source count=$(wc -l <"$SELECTED_INTERFACES" | tr -d '[:space:]') artifact=$SELECTED_INTERFACES"
log_file_with_label "QPS615-SELECTED-INTERFACE" "$SELECTED_INTERFACES" 16

while IFS= read -r qps_iface; do
    if ! grep -Fxq "$qps_iface" "$AVAILABLE_INTERFACES"; then
        test_result_record "FAIL" "Requested interface $qps_iface is not correlated with a QPS615 Ethernet function"
        continue
    fi

    if [ ! -d "/sys/class/net/$qps_iface" ]; then
        test_result_record "FAIL" "QPS615 interface $qps_iface disappeared before traffic validation"
        continue
    fi

    qps_carrier=$(ethv_get_carrier "$qps_iface")
    qps_ip=$(ethv_get_ipv4 "$qps_iface")
    qps_target="$QPS615_PEER"
    if [ -z "$qps_target" ]; then
        qps_target=$(ethv_get_default_gateway "$qps_iface")
    fi
    log_info "[QPS615-TRAFFIC] interface=$qps_iface selection=$selection_source carrier=${qps_carrier:-unknown} ipv4=${qps_ip:-none} peer=${qps_target:-none}"

    if [ "$qps_carrier" != "1" ]; then
        test_result_record "FAIL" "QPS615 interface $qps_iface has no carrier although the fixture was confirmed"
        continue
    fi
    if ! ethv_valid_ipv4 "$qps_ip"; then
        test_result_record "FAIL" "QPS615 interface $qps_iface has no configured IPv4 address although the traffic fixture was selected"
        continue
    fi
    if [ -z "$qps_target" ]; then
        test_result_record "FAIL" "QPS615 interface $qps_iface has no explicit peer or interface-specific default gateway although the traffic fixture was selected"
        continue
    fi
    if ! ethv_valid_unicast_ipv4 "$qps_target"; then
        test_result_record "FAIL" "QPS615 interface $qps_iface selected an invalid unicast IPv4 peer, observed=$qps_target"
        continue
    fi
    if [ "$qps_target" = "$qps_ip" ]; then
        test_result_record "FAIL" "QPS615 peer $qps_target is the local address of $qps_iface and cannot validate switch traffic"
        continue
    fi

    if ! ethv_counters_available \
        "$qps_iface" \
        rx_packets \
        tx_packets \
        rx_errors \
        tx_errors \
        rx_crc_errors \
        tx_carrier_errors; then
        test_result_record "FAIL" "QPS615 interface $qps_iface does not expose a usable $ETHV_COUNTER_FAILURE counter before traffic"
        continue
    fi

    before_rx=$(ethv_get_counter "$qps_iface" rx_packets)
    before_tx=$(ethv_get_counter "$qps_iface" tx_packets)
    before_rx_errors=$(ethv_get_counter "$qps_iface" rx_errors)
    before_tx_errors=$(ethv_get_counter "$qps_iface" tx_errors)
    before_crc=$(ethv_get_counter "$qps_iface" rx_crc_errors)
    before_carrier_errors=$(ethv_get_counter "$qps_iface" tx_carrier_errors)

    ping_log="$RESULT_DIR/${qps_iface}_ping.log"
    traffic_timeout=$((QPS615_PING_COUNT * QPS615_PING_WAIT + 10))
    if run_with_timeout_log \
        "$traffic_timeout" \
        "$ping_log" \
        ethv_ping_interface \
        "$qps_iface" \
        "$qps_target" \
        "$QPS615_PING_COUNT" \
        "$QPS615_PING_WAIT"; then
        ping_rc=0
    else
        ping_rc=$?
    fi

    if ! ethv_counters_available \
        "$qps_iface" \
        rx_packets \
        tx_packets \
        rx_errors \
        tx_errors \
        rx_crc_errors \
        tx_carrier_errors; then
        log_file_with_label "QPS615-PING-$qps_iface" "$ping_log" 20
        test_result_record "FAIL" "QPS615 interface $qps_iface lost its usable $ETHV_COUNTER_FAILURE counter after traffic, artifact=$ping_log"
        continue
    fi

    after_rx=$(ethv_get_counter "$qps_iface" rx_packets)
    after_tx=$(ethv_get_counter "$qps_iface" tx_packets)
    after_rx_errors=$(ethv_get_counter "$qps_iface" rx_errors)
    after_tx_errors=$(ethv_get_counter "$qps_iface" tx_errors)
    after_crc=$(ethv_get_counter "$qps_iface" rx_crc_errors)
    after_carrier_errors=$(ethv_get_counter "$qps_iface" tx_carrier_errors)
    rx_delta=$(ethv_counter_delta "$before_rx" "$after_rx")
    tx_delta=$(ethv_counter_delta "$before_tx" "$after_tx")
    rx_error_delta=$(ethv_counter_delta "$before_rx_errors" "$after_rx_errors")
    tx_error_delta=$(ethv_counter_delta "$before_tx_errors" "$after_tx_errors")
    crc_delta=$(ethv_counter_delta "$before_crc" "$after_crc")
    carrier_error_delta=$(ethv_counter_delta "$before_carrier_errors" "$after_carrier_errors")

    log_info "[QPS615-COUNTERS] interface=$qps_iface rx_packets_before=$before_rx rx_packets_after=$after_rx rx_packets_delta=$rx_delta tx_packets_before=$before_tx tx_packets_after=$after_tx tx_packets_delta=$tx_delta rx_errors_before=$before_rx_errors rx_errors_after=$after_rx_errors rx_errors_delta=$rx_error_delta tx_errors_before=$before_tx_errors tx_errors_after=$after_tx_errors tx_errors_delta=$tx_error_delta rx_crc_before=$before_crc rx_crc_after=$after_crc rx_crc_delta=$crc_delta tx_carrier_before=$before_carrier_errors tx_carrier_after=$after_carrier_errors tx_carrier_delta=$carrier_error_delta artifact=$ping_log"
    log_file_with_label "QPS615-PING-$qps_iface" "$ping_log" 20

    if [ "$ping_rc" -ne 0 ]; then
        test_result_record "FAIL" "QPS615 traffic to $qps_target failed on $qps_iface, rc=$ping_rc artifact=$ping_log"
    elif ! grep -Eq '(^|[[:space:],])0% packet loss' "$ping_log"; then
        test_result_record "FAIL" "QPS615 traffic to $qps_target completed with packet loss on $qps_iface, artifact=$ping_log"
    elif [ "$rx_delta" -le 0 ] || [ "$tx_delta" -le 0 ]; then
        test_result_record "FAIL" "QPS615 ping succeeded on $qps_iface but packet counters did not prove bidirectional traffic, rx_delta=$rx_delta tx_delta=$tx_delta"
    elif [ "$rx_error_delta" -ne 0 ] || [ "$tx_error_delta" -ne 0 ] ||
         [ "$crc_delta" -ne 0 ] || [ "$carrier_error_delta" -ne 0 ]; then
        test_result_record "FAIL" "QPS615 traffic increased hardware error counters on $qps_iface"
    else
        test_result_record "PASS" "QPS615 interface $qps_iface transferred bidirectional traffic to $qps_target without error-counter growth"
        QPS_TRAFFIC_PASS_COUNT=$((QPS_TRAFFIC_PASS_COUNT + 1))
    fi
done <"$SELECTED_INTERFACES"

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'tc956|qps615|stmmac|phylink|mdio|pci' \
    'Link is Down|Link down|carrier lost|no carrier'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for QPS615 traffic health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "QPS615-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "QPS615, PCIe, or Ethernet kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent QPS615 traffic-related kernel errors were found"
fi

if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$QPS_TRAFFIC_PASS_COUNT" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no selected QPS615 interface completed a traffic transfer"
fi

test_result_finish
