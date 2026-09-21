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
TESTNAME="DMA_BUF_Heap_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

DMABUF_HEAPS="${DMABUF_HEAPS:-auto}"
DMABUF_ALLOCATION_BYTES="${DMABUF_ALLOCATION_BYTES:-65536}"
DMABUF_TIMEOUT="${DMABUF_TIMEOUT:-15}"
DMABUF_MAX_ALLOCATION_BYTES=16777216
DMABUF_MAX_TIMEOUT=300
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
HEAP_INVENTORY="$RESULT_DIR/dmabuf_heaps.tsv"
SELECTED_HEAPS="$RESULT_DIR/selected_heaps.log"
DMABUF_PASS_COUNT=0

# usage
# Takes no arguments, prints the supported CLI contract to stdout, returns 0,
# and has no target-side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --heaps POLICY       auto, all, or a space-separated heap-name list" \
        "  --size BYTES         Page-aligned allocation size, 4096..16777216" \
        "  --timeout SECONDS    Per-heap watchdog, 1..300, default: 15" \
        "  -h, --help" \
        "Automatic mode selects standard CPU-mappable heaps discovered at runtime." \
        "CLI options override environment variables."
}

# parse_args <suite-arguments...>
# Applies CLI values to DMABUF_* globals without producing stdout. Returns 0 on
# success or 2 for an unknown option or missing value and has no other effects.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --heaps)
                [ "$#" -ge 2 ] || return 2
                DMABUF_HEAPS="$2"
                shift 2
                ;;
            --size)
                [ "$#" -ge 2 ] || return 2
                DMABUF_ALLOCATION_BYTES="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                DMABUF_TIMEOUT="$2"
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

# capture_heap_inventory <output-file>
# Discovers /dev/dma_heap entries and records name, type, and access flags in a
# TSV artifact. It produces no stdout, returns 0 on capture or 1 on file error,
# and does not alter heap permissions or device state.
capture_heap_inventory() {
    chi_output_file="$1"

    : >"$chi_output_file" || return 1
    printf 'name\tpath\tcharacter\treadable\twritable\n' \
        >"$chi_output_file" || return 1
    for chi_path in /dev/dma_heap/*; do
        [ -e "$chi_path" ] || continue
        chi_character=0
        chi_readable=0
        chi_writable=0
        [ -c "$chi_path" ] && chi_character=1
        [ -r "$chi_path" ] && chi_readable=1
        [ -w "$chi_path" ] && chi_writable=1
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${chi_path##*/}" \
            "$chi_path" \
            "$chi_character" \
            "$chi_readable" \
            "$chi_writable" >>"$chi_output_file" || return 1
    done
}

# select_heap_names <inventory-file> <policy> <output-file>
# Resolves auto, all, or a whitespace-separated explicit heap policy against a
# readable inventory. It emits no stdout, returns 0 when selection succeeds, 1
# when an explicit item is invalid or absent, or 3 for invalid input, and writes
# one selected heap name per line while exporting DMABUF_SELECTION_REASON.
select_heap_names() {
    shn_inventory_file="$1"
    shn_policy="$2"
    shn_output_file="$3"
    shn_requested_file="${shn_output_file}.requested"

    DMABUF_SELECTION_REASON=""
    export DMABUF_SELECTION_REASON
    [ -r "$shn_inventory_file" ] && [ -n "$shn_output_file" ] || return 3
    : >"$shn_output_file" || return 1

    case "$shn_policy" in
        auto|'')
            awk -F '\t' '
                NR > 1 && $3 == 1 && $4 == 1 && $5 == 1 &&
                ($1 == "system" || $1 == "system-uncached" ||
                 $1 == "qcom,system" || $1 == "linux,cma" ||
                 $1 == "cma" || $1 == "default_cma_region") {
                    print $1
                }
            ' "$shn_inventory_file" >"$shn_output_file" || return 1
            DMABUF_SELECTION_REASON="standard-cpu-mappable"
            ;;
        all)
            awk -F '\t' 'NR > 1 && $3 == 1 { print $1 }' \
                "$shn_inventory_file" >"$shn_output_file" || return 1
            DMABUF_SELECTION_REASON="all-character-heaps"
            ;;
        *)
            printf '%s\n' "$shn_policy" |
                awk '
                    {
                        for (field = 1; field <= NF; field++)
                            print $field
                    }
                ' >"$shn_requested_file" || return 1
            shn_selection_rc=0
            while IFS= read -r shn_name; do
                case "$shn_name" in
                    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,._+-]*)
                        DMABUF_SELECTION_REASON="invalid-heap-name-$shn_name"
                        shn_selection_rc=1
                        break
                        ;;
                esac
                if ! awk -F '\t' -v name="$shn_name" \
                    'NR > 1 && $1 == name && $3 == 1 { found = 1 } END { exit !found }' \
                    "$shn_inventory_file"; then
                    DMABUF_SELECTION_REASON="requested-heap-unavailable-$shn_name"
                    shn_selection_rc=1
                    break
                fi
                printf '%s\n' "$shn_name" >>"$shn_output_file"
            done <"$shn_requested_file"
            rm -f "$shn_requested_file"
            if [ "$shn_selection_rc" -ne 0 ]; then
                export DMABUF_SELECTION_REASON
                return 1
            fi
            sort -u "$shn_output_file" -o "$shn_output_file" || return 1
            DMABUF_SELECTION_REASON="explicit"
            ;;
    esac

    export DMABUF_SELECTION_REASON
    return 0
}

parse_args "$@" || {
    usage >&2
    exit 2
}

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "DMA-BUF heap validation: discovering heaps and proving allocation, mapping, CPU read/write, synchronization, zeroing, and descriptor release"
log_info "[DMABUF-POLICY] heaps=$DMABUF_HEAPS allocation_bytes=$DMABUF_ALLOCATION_BYTES timeout=${DMABUF_TIMEOUT}s network=not-required"

case "$DMABUF_ALLOCATION_BYTES" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "DMA-BUF allocation size and timeout must be positive integers"
        test_result_finish
        ;;
esac
case "$DMABUF_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "DMA-BUF allocation size and timeout must be positive integers"
        test_result_finish
        ;;
esac
if [ "${#DMABUF_ALLOCATION_BYTES}" -gt 8 ] ||
   [ "$DMABUF_ALLOCATION_BYTES" -gt "$DMABUF_MAX_ALLOCATION_BYTES" ]; then
    test_result_record "FAIL" "DMA-BUF allocation size exceeds the safe 16777216-byte limit"
    test_result_finish
fi
if [ "${#DMABUF_TIMEOUT}" -gt 3 ] ||
   [ "$DMABUF_TIMEOUT" -gt "$DMABUF_MAX_TIMEOUT" ]; then
    test_result_record "FAIL" "DMA-BUF timeout exceeds the safe 300-second limit"
    test_result_finish
fi

page_size=$(getconf PAGESIZE 2>/dev/null || printf '%s\n' 4096)
case "$page_size" in
    ''|*[!0-9]*|0)
        page_size=4096
        ;;
esac
if [ $((DMABUF_ALLOCATION_BYTES % page_size)) -ne 0 ]; then
    test_result_record "FAIL" "DMA-BUF allocation size must be page aligned, size=$DMABUF_ALLOCATION_BYTES page_size=$page_size"
    test_result_finish
fi
dmabuf_heap_config=$(kernel_config_value CONFIG_DMABUF_HEAPS 2>/dev/null || true)
dmabuf_system_config=$(kernel_config_value CONFIG_DMABUF_HEAPS_SYSTEM 2>/dev/null || true)
log_info "[DMABUF-DISCOVERY] device_root=/dev/dma_heap config=${dmabuf_heap_config:-unknown} system_config=${dmabuf_system_config:-unknown}"

if [ ! -d /dev/dma_heap ]; then
    case "$dmabuf_system_config" in
        CONFIG_DMABUF_HEAPS_SYSTEM=y|CONFIG_DMABUF_HEAPS_SYSTEM=m)
            test_result_record "FAIL" "Kernel enables the system DMA heap but /dev/dma_heap is absent"
            ;;
        *)
            test_result_record "SKIP" "DMA-BUF heap devices are not exposed on this target"
            ;;
    esac
    test_result_finish
fi

if ! capture_heap_inventory "$HEAP_INVENTORY"; then
    test_result_record "FAIL" "DMA-BUF heap inventory could not be captured"
    test_result_finish
fi
log_file_with_label "DMABUF-HEAP" "$HEAP_INVENTORY" 32
heap_count=$(awk 'NR > 1 { count++ } END { print count + 0 }' "$HEAP_INVENTORY")
if [ "$heap_count" -eq 0 ]; then
    test_result_record "FAIL" "/dev/dma_heap exists but exposes no heap device nodes"
    test_result_finish
fi
case "$dmabuf_system_config" in
    CONFIG_DMABUF_HEAPS_SYSTEM=y|CONFIG_DMABUF_HEAPS_SYSTEM=m)
        if ! awk -F '\t' \
            'NR > 1 && $1 == "system" && $3 == 1 { found = 1 } END { exit !found }' \
            "$HEAP_INVENTORY"; then
            test_result_record "FAIL" "Kernel enables the system DMA heap but /dev/dma_heap/system is not a character device"
            test_result_finish
        fi
        ;;
esac

if ! select_heap_names "$HEAP_INVENTORY" "$DMABUF_HEAPS" "$SELECTED_HEAPS"; then
    test_result_record "FAIL" "DMA-BUF heap selection is invalid, reason=${DMABUF_SELECTION_REASON:-unknown}"
    test_result_finish
fi
selected_count=$(wc -l <"$SELECTED_HEAPS" | tr -d '[:space:]')
if [ "$selected_count" -eq 0 ]; then
    test_result_record "SKIP" "No standard CPU-mappable DMA-BUF heap was discovered, use --heaps only when a product contract identifies a safe heap"
    test_result_finish
fi
log_info "[DMABUF-SELECTION] source=$DMABUF_SELECTION_REASON count=$selected_count artifact=$SELECTED_HEAPS"
log_file_with_label "DMABUF-SELECTED" "$SELECTED_HEAPS" 32

PYTHON_COMMAND=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_COMMAND=$(command -v python3)
elif command -v python >/dev/null 2>&1 &&
     python -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' \
        >/dev/null 2>&1; then
    PYTHON_COMMAND=$(command -v python)
fi
if [ -z "$PYTHON_COMMAND" ]; then
    test_result_record "SKIP" "Image-provided Python 3 is unavailable, the dependency-free DMA-BUF UAPI client cannot run"
    test_result_finish
fi

while IFS= read -r dmabuf_heap_name; do
    [ -n "$dmabuf_heap_name" ] || continue
    dmabuf_heap_path="/dev/dma_heap/$dmabuf_heap_name"
    dmabuf_safe_name=$(printf '%s' "$dmabuf_heap_name" | sed 's/[^A-Za-z0-9.-]/-/g')
    dmabuf_log="$RESULT_DIR/heap-${dmabuf_safe_name}.log"
    dmabuf_report="$RESULT_DIR/heap-${dmabuf_safe_name}.tsv"
    log_info "[DMABUF-FUNCTIONAL] phase=start heap=$dmabuf_heap_name path=$dmabuf_heap_path bytes=$DMABUF_ALLOCATION_BYTES timeout=${DMABUF_TIMEOUT}s"
    run_with_timeout_log \
        "$DMABUF_TIMEOUT" \
        "$dmabuf_log" \
        "$PYTHON_COMMAND" "$TOOLS/dmabuf_heap_runner.py" \
            --heap "$dmabuf_heap_path" \
            --size "$DMABUF_ALLOCATION_BYTES" \
            --report "$dmabuf_report"
    dmabuf_rc=$?
    log_file_with_label "DMABUF-FUNCTIONAL" "$dmabuf_log" 20
    log_file_with_label "DMABUF-REPORT" "$dmabuf_report" 30
    dmabuf_status="missing"
    if [ -r "$dmabuf_report" ]; then
        dmabuf_status=$(sed -n 's/^status[[:space:]]//p' "$dmabuf_report" | sed -n '1p')
        [ -n "$dmabuf_status" ] || dmabuf_status="missing"
    fi

    if [ "$dmabuf_rc" -eq 0 ] && [ "$dmabuf_status" = "PASS" ]; then
        test_result_record "PASS" "DMA-BUF heap $dmabuf_heap_name completed allocate, map, zero-check, synchronized write/read, and free validation"
        DMABUF_PASS_COUNT=$((DMABUF_PASS_COUNT + 1))
    else
        test_result_record "FAIL" "DMA-BUF heap $dmabuf_heap_name functional validation failed, rc=$dmabuf_rc report_status=$dmabuf_status log=$dmabuf_log report=$dmabuf_report"
    fi
done <"$SELECTED_HEAPS"

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'dma[-_ ]?heap|dma[-_ ]?buf' \
    'dma_buf:.*debugfs statistics unavailable'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for DMA-BUF heap health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "DMABUF-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "DMA-BUF heap kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent DMA-BUF heap kernel errors were found"
fi

if [ "$TEST_RESULT_FAIL_COUNT" -eq 0 ] && [ "$DMABUF_PASS_COUNT" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no selected DMA-BUF heap completed the functional transaction"
fi

test_result_finish
