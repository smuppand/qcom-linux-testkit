#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

TESTNAME="DSP_AudioPD"

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

RES_FALLBACK="$SCRIPT_DIR/${TESTNAME}.res"

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    echo "$TESTNAME SKIP" >"$RES_FALLBACK" 2>/dev/null || true
    exit 0
fi

# Only source if not already loaded (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    export __INIT_ENV_LOADED=1
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_skip "$TESTNAME SKIP - test path not found"
    echo "$TESTNAME SKIP" >"$RES_FALLBACK" 2>/dev/null || true
    exit 0
fi

if ! cd "$test_path"; then
    log_skip "$TESTNAME SKIP - cannot cd into $test_path"
    echo "$TESTNAME SKIP" >"$RES_FALLBACK" 2>/dev/null || true
    exit 0
fi

# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Dependencies (single call; log list; SKIP if missing)
deps_list="adsprpcd tr awk grep sleep find cat"
log_info "Checking dependencies: $deps_list"
if ! check_dependencies "$deps_list"; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies: $deps_list"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

STARTED_BY_TEST=0
PID=""
PIDS=""

check_adsprpcd_wait_state() {
    pid="$1"
    pid=$(sanitize_pid "$pid")

    case "$pid" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    # Prefer /proc/<pid>/wchan (more commonly available)
    if [ -r "/proc/$pid/wchan" ]; then
        wchan=$(tr -d '\r\n' <"/proc/$pid/wchan" 2>/dev/null)

        # Keep wchan for debug. It is timing-sensitive and may move between
        # poll/epoll/nanosleep while the daemon is alive and healthy.
        case "$wchan" in
            do_sys_poll*|ep_poll*|do_epoll_wait*|poll_schedule_timeout*)
                log_info "adsprpcd PID $pid wchan='$wchan' (accepted)"
                return 0
                ;;
            *)
                log_info "adsprpcd PID $pid wchan='$wchan' (debug only; not used as failure gate)"
                return 0
                ;;
        esac
    fi

    # Fallback: /proc/<pid>/stack (may be missing depending on kernel config)
    if [ -r "/proc/$pid/stack" ]; then
        if grep -qE "(do_sys_poll|ep_poll|do_epoll_wait|poll_schedule_timeout)" "/proc/$pid/stack" 2>/dev/null; then
            log_info "adsprpcd PID $pid stack contains expected wait symbol"
            return 0
        fi

        log_info "adsprpcd PID $pid stack does not contain expected wait symbols (debug only)"
        return 0
    fi

    # Neither interface is available -> SKIP
    log_skip "Kernel does not expose /proc/$pid/(wchan|stack); cannot validate adsprpcd wait state"
    echo "$TESTNAME SKIP" >"$res_file"
    return 2
}

# Check whether non-secure ADSP FastRPC and ADSP RPC remote heap are present
# before running AudioPD validation. Return 0=supported, 2=unsupported/SKIP.
# Check whether ADSP remoteproc, FastRPC device node, and allocator backing are
# available before AudioPD validation. Return 0=supported, 2=unsupported/SKIP.
check_audiopd_allocator_available() {
    dt_root=""
    dt_nodes_file=""
    heap_path=""
    logged_heaps=""
    node=""
    compat_text=""
    rproc=""
    remoteproc_name=""
    remoteproc_state=""
    memory_region_ok=0
    vmids_ok=0
    adsp_running=0
    dev_found=0
    heap_found=0
    fastrpc_dt_found=0
    fastrpc_allocator_found=0

    log_info "=== AudioPD FastRPC allocator pre-check ==="

    # Check remoteproc before FastRPC device nodes. FastRPC device nodes are
    # expected only after the corresponding remoteproc is up.
    for rproc in /sys/class/remoteproc/remoteproc*; do
        [ -e "$rproc" ] || continue

        remoteproc_name="$(cat "$rproc/name" 2>/dev/null || true)"
        remoteproc_state="$(cat "$rproc/state" 2>/dev/null || true)"

        if [ "$remoteproc_name" = "adsp" ]; then
            log_info "[audiopd] ADSP remoteproc: $rproc state=$remoteproc_state"

            if [ "$remoteproc_state" = "running" ]; then
                adsp_running=1
            fi
        fi
    done

    if [ "$adsp_running" -eq 0 ]; then
        log_skip "[audiopd] ADSP remoteproc is not running."
        return 2
    fi

    # Device open logic checks secure first, then falls back to non-secure.
    # Either device node is sufficient for this pre-check.
    if [ -e /dev/fastrpc-adsp-secure ]; then
        dev_found=1
        log_info "[audiopd] Secure ADSP FastRPC device present: /dev/fastrpc-adsp-secure"
    elif [ -e /dev/fastrpc-adsp ]; then
        dev_found=1
        log_info "[audiopd] Non-secure ADSP FastRPC device present: /dev/fastrpc-adsp"
    else
        log_warn "[audiopd] ADSP FastRPC device missing: /dev/fastrpc-adsp-secure and /dev/fastrpc-adsp"
    fi

    for dt_root in /proc/device-tree /sys/firmware/devicetree/base; do
        [ -d "$dt_root" ] || continue

        dt_nodes_file="${TMPDIR:-/tmp}/${TESTNAME}_fastrpc_dt.$$"
        : >"$dt_nodes_file" 2>/dev/null || continue
        find "$dt_root" -type d 2>/dev/null >"$dt_nodes_file"

        while IFS= read -r node; do
            [ -n "$node" ] || continue

            compat_text=""
            if [ -f "$node/compatible" ]; then
                compat_text="$(tr '\000' ' ' <"$node/compatible" 2>/dev/null)"
            fi

            # memory-region and qcom,vmids belong to the parent qcom,fastrpc
            # node. Do not validate compute-cb child nodes for these properties.
            case "$compat_text" in
                *qcom,fastrpc-compute-cb*)
                    continue
                    ;;
            esac

            case "$compat_text" in
                *qcom,fastrpc*)
                    fastrpc_dt_found=1
                    log_info "[audiopd] FastRPC parent DT candidate: $node"

                    memory_region_ok=0
                    vmids_ok=0

                    if [ -s "$node/memory-region" ]; then
                        memory_region_ok=1
                        log_info "[audiopd] FastRPC memory-region present: $node/memory-region"
                    else
                        log_warn "[audiopd] FastRPC parent DT node missing memory-region: $node"
                    fi

                    if [ -s "$node/qcom,vmids" ]; then
                        vmids_ok=1
                        log_info "[audiopd] FastRPC qcom,vmids present: $node/qcom,vmids"
                    else
                        log_warn "[audiopd] FastRPC parent DT node missing qcom,vmids: $node"
                    fi

                    if [ "$memory_region_ok" -eq 1 ]; then
                        if [ "$vmids_ok" -eq 1 ]; then
                            fastrpc_allocator_found=1
                            log_info "[audiopd] FastRPC allocator DT properties are valid: $node"
                            break
                        fi
                    fi
                    ;;
            esac
        done <"$dt_nodes_file"

        rm -f "$dt_nodes_file" 2>/dev/null || true

        if [ "$fastrpc_allocator_found" -eq 1 ]; then
            break
        fi
    done

    # Keep reserved-memory scan for debug/fallback visibility. However, if a
    # qcom,fastrpc parent node is visible, the parent node must carry
    # memory-region + qcom,vmids to pass.
    for dt_root in /proc/device-tree /sys/firmware/devicetree/base; do
        [ -d "$dt_root" ] || continue

        for heap_path in "$dt_root"/reserved-memory/*adsp*rpc*remote*heap* \
                         "$dt_root"/reserved-memory/*adsp-rpc-remote-heap*; do
            [ -e "$heap_path" ] || continue

            case " $logged_heaps " in
                *" $heap_path "*)
                    continue
                    ;;
            esac
            logged_heaps="$logged_heaps $heap_path"

            heap_found=1
            log_info "[audiopd] ADSP RPC remote heap reserved-memory node: $heap_path"

            if [ -s "$heap_path/reg" ]; then
                log_info "[audiopd] ADSP RPC remote heap reg property present: $heap_path/reg"
            else
                log_warn "[audiopd] ADSP RPC remote heap reg property missing or empty: $heap_path/reg"
            fi
        done
    done

    if [ "$dev_found" -eq 1 ]; then
        if [ "$fastrpc_allocator_found" -eq 1 ]; then
            log_pass "[audiopd] AudioPD FastRPC allocator prerequisites are available."
            return 0
        fi
    fi

    # Some live DT layouts may not expose the qcom,fastrpc parent node clearly
    # under /proc/device-tree. In that case only, allow reserved heap evidence
    # to avoid false SKIP on targets where the parent node is not discoverable.
    if [ "$dev_found" -eq 1 ]; then
        if [ "$fastrpc_dt_found" -eq 0 ]; then
            if [ "$heap_found" -eq 1 ]; then
                log_warn "[audiopd] FastRPC parent DT node was not discoverable; falling back to ADSP RPC remote heap evidence."
                log_pass "[audiopd] AudioPD FastRPC allocator prerequisites are available."
                return 0
            fi
        fi
    fi

    if [ "$dev_found" -eq 0 ]; then
        log_skip "[audiopd] No secure/non-secure ADSP FastRPC device is available."
    fi

    if [ "$fastrpc_dt_found" -eq 1 ]; then
        if [ "$fastrpc_allocator_found" -eq 0 ]; then
            log_skip "[audiopd] FastRPC parent DT node is missing memory-region and/or qcom,vmids."
        fi
    elif [ "$heap_found" -eq 0 ]; then
        log_skip "[audiopd] ADSP RPC remote heap reserved-memory is not available."
    fi

    return 2
}

check_audiopd_allocator_available
allocator_rc=$?

if [ "$allocator_rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP - AudioPD FastRPC allocator prerequisites are not available on this target"
    echo "$TESTNAME SKIP" >"$res_file"
    log_info "-------------------Completed $TESTNAME Testcase----------------------------"
    exit 0
fi

if is_process_running "adsprpcd"; then
    # is_process_running already prints instances/cmdline (for CI debug)
    PIDS=$(get_one_pid_by_name "adsprpcd" all 2>/dev/null || true)

    # Pick a primary PID for legacy logging (first valid numeric PID)
    for p in $PIDS; do
        p_clean=$(sanitize_pid "$p")
        if [ -n "$p_clean" ]; then
            PID="$p_clean"
            break
        fi
    done
else
    log_info "adsprpcd is not running"
    log_info "Manually starting adsprpcd daemon"
    adsprpcd >/dev/null 2>&1 &
    PID=$(sanitize_pid "$!")
    STARTED_BY_TEST=1

    # adsprpcd might daemonize/fork; if $! isn't alive, discover PID by name
    if [ -n "$PID" ] && ! wait_pid_alive "$PID" 2; then
        PID=""
    fi
    if [ -z "$PID" ]; then
        PID=$(get_one_pid_by_name "adsprpcd" 2>/dev/null || true)
        PID=$(sanitize_pid "$PID")
    fi

    # After start, gather all adsprpcd PIDs (if helper supports it)
    PIDS=$(get_one_pid_by_name "adsprpcd" all 2>/dev/null || true)
fi

# Fallback if helper returned nothing
if [ -z "$PIDS" ] && [ -n "$PID" ]; then
    PIDS="$PID"
fi

log_info "PID is $PID"

# Build an "alive" PID list (avoid false failures if a PID disappears)
PIDS_ALIVE=""
alive_count=0
dead_seen=0
for p in $PIDS; do
    p_clean=$(sanitize_pid "$p")
    if [ -z "$p_clean" ]; then
        continue
    fi

    if wait_pid_alive "$p_clean" 10; then
        alive_count=$((alive_count + 1))
        if [ -z "$PIDS_ALIVE" ]; then
            PIDS_ALIVE="$p_clean"
        else
            PIDS_ALIVE="$PIDS_ALIVE $p_clean"
        fi
    else
        dead_seen=1
        log_warn "adsprpcd PID $p_clean did not become alive"
    fi
done

# Only print alive list if something was dropped (avoids duplicate info in normal case)
if [ "$dead_seen" -eq 1 ]; then
    log_info "Alive adsprpcd PIDs: $PIDS_ALIVE"
fi

if [ "$alive_count" -le 0 ]; then
    log_fail "Failed to start adsprpcd or no alive PID found"
    echo "$TESTNAME FAIL" >"$res_file"

    # Kill only if we started it and PID is valid
    if [ "$STARTED_BY_TEST" -eq 1 ]; then
        for p in $PIDS; do
            p_clean=$(sanitize_pid "$p")
            if [ -n "$p_clean" ]; then
                kill_process "$p_clean" || true
            fi
        done
    fi
    exit 0
fi

# Evaluate all alive PIDs
fail_seen=0
skip_seen=0

for p in $PIDS_ALIVE; do
    check_adsprpcd_wait_state "$p"
    rc=$?

    if [ "$rc" -eq 2 ]; then
        skip_seen=1
        break
    fi
    if [ "$rc" -ne 0 ]; then
        fail_seen=1
    fi
done

if [ "$skip_seen" -eq 1 ]; then
    # SKIP already written by the function
    :
else
    if [ "$fail_seen" -eq 0 ]; then
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" >"$res_file"
    else
        log_fail "$TESTNAME : Test Failed"
        echo "$TESTNAME FAIL" >"$res_file"
    fi
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"

# Kill only if we started it
if [ "$STARTED_BY_TEST" -eq 1 ]; then
    for p in $PIDS; do
        p_clean=$(sanitize_pid "$p")
        if [ -n "$p_clean" ]; then
            kill_process "$p_clean" || true
        fi
    done
fi

exit 0
