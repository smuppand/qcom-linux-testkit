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
. "$TOOLS/lib_bus.sh"
TESTNAME="UART_Loopback_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
UART_DEVICE="${UART_DEVICE:-}"
UART_BAUDS="${UART_BAUDS:-${UART_BAUD:-auto}}"
UART_DATA_BITS="${UART_DATA_BITS:-8}"
UART_FLOW_CONTROL="${UART_FLOW_CONTROL:-none}"
UART_LOOPBACK_TYPE="${UART_LOOPBACK_TYPE:-external}"
UART_PAYLOAD_BYTES="${UART_PAYLOAD_BYTES:-4096}"
UART_LOOPBACK_TIMEOUT="${UART_LOOPBACK_TIMEOUT:-10}"
UART_LOOPBACK_FIXTURE="${UART_LOOPBACK_FIXTURE:-0}"

cleanup() {
    uart_loopback_cleanup >/dev/null 2>&1 || true
}

usage() {
    cat <<EOF
Usage: $0 [options]
  --device PATH       Override auto-detection with a non-console UART device
  --baud LIST         Comma-separated baud rates, default: $UART_BAUDS
  --data-bits LIST    Comma-separated character widths (5,6,7,8), default: $UART_DATA_BITS
  --flow-control TYPE none or rtscts, default: $UART_FLOW_CONTROL
  --loopback TYPE     internal or external, default: $UART_LOOPBACK_TYPE
  --payload-bytes N   Bytes transferred at each baud, default: $UART_PAYLOAD_BYTES
  --timeout SECONDS   Read and write timeout, default: $UART_LOOPBACK_TIMEOUT
  --fixture            Confirm external TX/RX wiring or a USB-to-UART peer echo
  -h, --help          Show this help

Legacy-compatible aliases: -l selects internal loopback, -d maps to --device,
  -b maps to --baud, -s maps to --payload-bytes, -c maps to --data-bits, and
  -f accepts 0 for none or 1 for rtscts flow control.

Environment equivalents: UART_DEVICE, UART_BAUDS, UART_DATA_BITS,
  UART_FLOW_CONTROL, UART_LOOPBACK_TYPE, UART_PAYLOAD_BYTES, UART_LOOPBACK_TIMEOUT,
  UART_LOOPBACK_FIXTURE. UART_BAUD remains a compatible single-value fallback.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --device|-d)
                [ "$#" -ge 2 ] || return 2
                UART_DEVICE="$2"
                shift 2
                ;;
            --baud|-b)
                [ "$#" -ge 2 ] || return 2
                UART_BAUDS="$2"
                shift 2
                ;;
            --data-bits|-c)
                [ "$#" -ge 2 ] || return 2
                UART_DATA_BITS="$2"
                shift 2
                ;;
            --flow-control|-f)
                [ "$#" -ge 2 ] || return 2
                case "$2" in
                    0)
                        UART_FLOW_CONTROL=none
                        ;;
                    1)
                        UART_FLOW_CONTROL=rtscts
                        ;;
                    *)
                        UART_FLOW_CONTROL="$2"
                        ;;
                esac
                shift 2
                ;;
            --loopback)
                [ "$#" -ge 2 ] || return 2
                UART_LOOPBACK_TYPE="$2"
                shift 2
                ;;
            --payload-bytes|-s)
                [ "$#" -ge 2 ] || return 2
                UART_PAYLOAD_BYTES="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                UART_LOOPBACK_TIMEOUT="$2"
                shift 2
                ;;
            --fixture)
                UART_LOOPBACK_FIXTURE=1
                shift
                ;;
            -l)
                UART_LOOPBACK_TYPE=internal
                shift
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

validate_config() {
    for numeric_value in "$UART_PAYLOAD_BYTES" "$UART_LOOPBACK_TIMEOUT"; do
        case "$numeric_value" in
            ''|*[!0-9]*|0)
                log_error "Payload bytes and timeout must be positive integers"
                return 2
                ;;
        esac
    done

    if [ -z "$UART_BAUDS" ]; then
        log_error "UART baud list must not be empty"
        return 2
    fi
    if [ "$UART_BAUDS" != "auto" ]; then
        case "$UART_BAUDS" in
            ,*|*,|*,,*)
                log_error "UART baud list contains an empty element: $UART_BAUDS"
                return 2
                ;;
        esac
        validate_uart_remaining_bauds=$UART_BAUDS
        while [ -n "$validate_uart_remaining_bauds" ]; do
            case "$validate_uart_remaining_bauds" in
                *,*)
                    validate_uart_baud=${validate_uart_remaining_bauds%%,*}
                    validate_uart_remaining_bauds=${validate_uart_remaining_bauds#*,}
                    ;;
                *)
                    validate_uart_baud=$validate_uart_remaining_bauds
                    validate_uart_remaining_bauds=""
                    ;;
            esac
            case "$validate_uart_baud" in
                ''|*[!0-9]*|0)
                    log_error "UART baud rates must be positive integers: $validate_uart_baud"
                    return 2
                    ;;
            esac
        done
    fi

    case "$UART_DATA_BITS" in
        ''|,*|*,|*,,*)
            log_error "UART data-bit list is empty or contains an empty element: $UART_DATA_BITS"
            return 2
            ;;
    esac
    validate_uart_remaining_data_bits=$UART_DATA_BITS
    while [ -n "$validate_uart_remaining_data_bits" ]; do
        case "$validate_uart_remaining_data_bits" in
            *,*)
                validate_uart_data_bits=${validate_uart_remaining_data_bits%%,*}
                validate_uart_remaining_data_bits=${validate_uart_remaining_data_bits#*,}
                ;;
            *)
                validate_uart_data_bits=$validate_uart_remaining_data_bits
                validate_uart_remaining_data_bits=""
                ;;
        esac
        case "$validate_uart_data_bits" in
            5|6|7|8)
                ;;
            *)
                log_error "UART data bits must be one of 5, 6, 7, or 8: $validate_uart_data_bits"
                return 2
                ;;
        esac
    done

    case "$UART_FLOW_CONTROL" in
        none|rtscts)
            ;;
        *)
            log_error "UART flow control must be none or rtscts: $UART_FLOW_CONTROL"
            return 2
            ;;
    esac

    case "$UART_LOOPBACK_TYPE" in
        internal|external)
            ;;
        *)
            log_error "UART loopback type must be internal or external: $UART_LOOPBACK_TYPE"
            return 2
            ;;
    esac

}

if ! parse_args "$@"; then
    usage >&2
    exit 2
fi
if ! validate_config; then
    usage >&2
    exit 2
fi

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
trap cleanup EXIT HUP INT TERM

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
if ! bus_validation_require_commands awk basename cksum cmp grep mkdir od readlink rm sh sleep stty tr wc; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required image-provided UART loopback utilities are unavailable"
fi
if [ "$UART_LOOPBACK_TYPE" = external ] &&
   ! bus_validation_bool_true "$UART_LOOPBACK_FIXTURE"; then
    test_result_finish "SKIP" "$TESTNAME SKIP: external UART loopback fixture was not explicitly enabled, use --fixture or UART_LOOPBACK_FIXTURE=1"
fi
if [ "$UART_LOOPBACK_TYPE" = external ] &&
   ! bus_validation_require_commands dd; then
    test_result_finish "SKIP" "$TESTNAME SKIP: dd is unavailable for external UART loopback"
fi
if [ "$UART_LOOPBACK_TYPE" = internal ] &&
   ! bus_validation_require_commands python3; then
    test_result_finish "SKIP" "$TESTNAME SKIP: python3 is unavailable for TIOCM_LOOP validation"
fi
if [ "$UART_LOOPBACK_TYPE" = internal ] &&
   [ ! -r "$TOOLS/uart_tiocm_loopback.py" ]; then
    test_result_finish "FAIL" "$TESTNAME FAIL: internal loopback helper is unavailable at $TOOLS/uart_tiocm_loopback.py"
fi

log_info "UART discovery: evaluating runtime DT-backed physical TTYs for access, console use, active owners, driver binding, and runtime PM"
if ! uart_loopback_report_candidates "$RESULT_DIR/uart_candidates.tsv"; then
    log_warn "UART candidate diagnostics could not be completed, continuing with capability-driven selection"
fi

UART_SELECTED_DEVICES="$RESULT_DIR/uart_selected_devices.log"
: >"$UART_SELECTED_DEVICES"
UART_SELECTION_SOURCE=override
if [ -n "$UART_DEVICE" ]; then
    printf '%s\n' "$UART_DEVICE" >"$UART_SELECTED_DEVICES"
elif [ "$UART_LOOPBACK_TYPE" = internal ]; then
    UART_SELECTION_SOURCE=auto-all
    uart_loopback_list_devices >"$UART_SELECTED_DEVICES" 2>/dev/null
    UART_SELECTION_STATUS=$?
    if [ "$UART_SELECTION_STATUS" -ne 0 ]; then
        if [ "$UART_SELECTION_STATUS" -ne 2 ]; then
            test_result_finish "FAIL" "$TESTNAME FAIL: UART device discovery failed with status $UART_SELECTION_STATUS"
        fi
    fi
else
    UART_SELECTION_SOURCE=auto-unique
    UART_SELECTED_DEVICE=$(uart_loopback_select_device 2>/dev/null)
    UART_SELECTION_STATUS=$?
    if [ "$UART_SELECTION_STATUS" -eq 1 ]; then
        test_result_finish "SKIP" "$TESTNAME SKIP: multiple unused DT-backed non-console UART devices were detected, CI cannot infer which port has the external return path, select one with --device or UART_DEVICE"
    fi
    if [ "$UART_SELECTION_STATUS" -eq 0 ] && [ -n "$UART_SELECTED_DEVICE" ]; then
        printf '%s\n' "$UART_SELECTED_DEVICE" >"$UART_SELECTED_DEVICES"
    fi
fi
if [ ! -s "$UART_SELECTED_DEVICES" ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no accessible unused DT-backed physical non-console UART was detected"
fi
UART_SELECTED_COUNT=$(awk 'NF { count++ } END { print count + 0 }' "$UART_SELECTED_DEVICES")
UART_FIXTURE_STATE=not-required
if [ "$UART_LOOPBACK_TYPE" = external ]; then
    UART_FIXTURE_STATE=external-confirmed
fi
log_info "UART selection: source=$UART_SELECTION_SOURCE selected_devices=$UART_SELECTED_COUNT list=$UART_SELECTED_DEVICES"
while IFS= read -r UART_SELECTED_LOG_DEVICE; do
    [ -n "$UART_SELECTED_LOG_DEVICE" ] || continue
    log_info "[UART-SELECTION] device=$UART_SELECTED_LOG_DEVICE source=$UART_SELECTION_SOURCE loopback=$UART_LOOPBACK_TYPE"
done <"$UART_SELECTED_DEVICES"

log_info "UART loopback: validating each selected device sequentially across the requested baud and character-width matrix"
UART_REQUESTED_BAUDS=$UART_BAUDS
while IFS= read -r UART_DEVICE; do
    [ -n "$UART_DEVICE" ] || continue
    UART_DEVICE_NAME=$(basename "$UART_DEVICE")
    UART_DEVICE_RESULT_DIR="$RESULT_DIR/$UART_DEVICE_NAME"
    if ! mkdir -p "$UART_DEVICE_RESULT_DIR"; then
        test_result_record "FAIL" "UART evidence directory could not be created for $UART_DEVICE at $UART_DEVICE_RESULT_DIR"
        continue
    fi

    UART_DEVICE_BAUDS=$UART_REQUESTED_BAUDS
    if [ "$UART_DEVICE_BAUDS" = "auto" ]; then
        UART_DEVICE_BAUDS=$(uart_loopback_select_bauds "$UART_DEVICE")
        UART_BAUD_SELECTION_STATUS=$?
        if [ "$UART_BAUD_SELECTION_STATUS" -ne 0 ] || [ -z "$UART_DEVICE_BAUDS" ]; then
            test_result_record "FAIL" "Could not derive a baud matrix for $UART_DEVICE"
            continue
        fi
    fi
    log_info "Configuration: device=$UART_DEVICE selection=$UART_SELECTION_SOURCE loopback=$UART_LOOPBACK_TYPE bauds=$UART_DEVICE_BAUDS data_bits=$UART_DATA_BITS flow_control=$UART_FLOW_CONTROL payload_bytes=$UART_PAYLOAD_BYTES timeout=${UART_LOOPBACK_TIMEOUT}s fixture=$UART_FIXTURE_STATE evidence=$UART_DEVICE_RESULT_DIR"

    UART_REMAINING_BAUDS=$UART_DEVICE_BAUDS
    while [ -n "$UART_REMAINING_BAUDS" ]; do
        case "$UART_REMAINING_BAUDS" in
            *,*)
                UART_BAUD=${UART_REMAINING_BAUDS%%,*}
                UART_REMAINING_BAUDS=${UART_REMAINING_BAUDS#*,}
                ;;
            *)
                UART_BAUD=$UART_REMAINING_BAUDS
                UART_REMAINING_BAUDS=""
                ;;
        esac
        UART_REMAINING_DATA_BITS=$UART_DATA_BITS
        while [ -n "$UART_REMAINING_DATA_BITS" ]; do
            case "$UART_REMAINING_DATA_BITS" in
                *,*)
                    UART_CASE_DATA_BITS=${UART_REMAINING_DATA_BITS%%,*}
                    UART_REMAINING_DATA_BITS=${UART_REMAINING_DATA_BITS#*,}
                    ;;
                *)
                    UART_CASE_DATA_BITS=$UART_REMAINING_DATA_BITS
                    UART_REMAINING_DATA_BITS=""
                    ;;
            esac
            UART_CASE_ID="${UART_BAUD}_${UART_CASE_DATA_BITS}bit_${UART_FLOW_CONTROL}_${UART_LOOPBACK_TYPE}"
            UART_CASE_LOG="$UART_DEVICE_RESULT_DIR/uart_loopback_${UART_CASE_ID}.log"
            log_info "---- UART functional case: device=$UART_DEVICE loopback=$UART_LOOPBACK_TYPE baud=$UART_BAUD data_bits=$UART_CASE_DATA_BITS flow_control=$UART_FLOW_CONTROL bytes=$UART_PAYLOAD_BYTES ----"
            uart_loopback_validate \
                "$UART_DEVICE" \
                "$UART_BAUD" \
                "$UART_LOOPBACK_TIMEOUT" \
                "$UART_DEVICE_RESULT_DIR" \
                "$UART_PAYLOAD_BYTES" \
                "$UART_CASE_DATA_BITS" \
                "$UART_FLOW_CONTROL" \
                "$UART_LOOPBACK_TYPE" \
                "$TOOLS/uart_tiocm_loopback.py"
            loopback_status=$?
            case "$loopback_status" in
                0)
                    test_result_record "PASS" "UART $UART_LOOPBACK_TYPE exact payload transfer passed on $UART_DEVICE at $UART_BAUD baud with $UART_CASE_DATA_BITS data bits and $UART_FLOW_CONTROL flow control"
                    ;;
                1)
                    uart_loopback_capture_failure_diagnostics \
                        "$UART_DEVICE" \
                        "$UART_DEVICE_RESULT_DIR" \
                        "$UART_CASE_ID" ||
                        log_warn "UART failure diagnostics could not be completed for $UART_DEVICE"
                    test_result_record "FAIL" "UART $UART_LOOPBACK_TYPE loopback failed on $UART_DEVICE at $UART_BAUD baud with $UART_CASE_DATA_BITS data bits and $UART_FLOW_CONTROL flow control, see $UART_CASE_LOG and preceding UART-RESTORE diagnostics"
                    ;;
                2)
                    test_result_record "SKIP" "UART $UART_LOOPBACK_TYPE loopback at $UART_BAUD baud is not runnable on $UART_DEVICE, the preceding UART-LOOPBACK line identifies the reason"
                    ;;
                *)
                    test_result_record "FAIL" "UART loopback helper returned unexpected status $loopback_status on $UART_DEVICE at $UART_BAUD baud with $UART_CASE_DATA_BITS data bits"
                    ;;
            esac
        done
    done
done <"$UART_SELECTED_DEVICES"

test_result_finish
