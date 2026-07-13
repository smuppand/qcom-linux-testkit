#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Shared helpers for DIAG userspace functional validation.

# Expected globals provided by the caller:
# DIAG_RESULT_TABLE
# DIAG_RUN_DIR
# DIAG_MDLOG_HELP_FILE
# DIAG_DURATION_SECS
# DIAG_NRT_DURATION_SECS
# DIAG_STARTUP_TIMEOUT_SECS
# DIAG_STOP_TIMEOUT_SECS
# DIAG_FILE_SIZE
# DIAG_FILE_COUNT
# DIAG_MASK_FILE
# DIAG_MASK_LIST
# DIAG_PERIPHERAL_MASK
# DIAG_PROCESSOR_MASK
# DIAG_USERPD_MASK
# DIAG_QDSS_MASK
# DIAG_TX_MODE
# DIAG_BUFFER_PERIPHERAL_MASK
# DIAG_ETR_BUFFER_SIZE
# DIAG_QMDL2_V2

DIAG_OWNED_PIDS=""
DIAG_MDLOG_PATH=""
DIAG_EXPLICIT_MASK=0
DIAG_SESSION_VALIDATED=0
DIAG_SESSION_CONFLICT=0
DIAG_LAST_PID=""
DIAG_LAST_LOG=""
DIAG_LAST_OUTPUT_ROOT=""
DIAG_LAST_OUTPUT_DIR=""
DIAG_ROUTER_PID=""
DIAG_ROUTER_LOG=""
DIAG_ROUTER_OWNED=0

diag_has_validated_session() {
    [ "${DIAG_SESSION_VALIDATED:-0}" -eq 1 ]
}

diag_has_session_conflict() {
    [ "${DIAG_SESSION_CONFLICT:-0}" -eq 1 ]
}

# Convert arbitrary command output to one safe summary-table field.
diag_sanitize_text() {
    printf '%s' "${1:-}" \
        | tr '\n\r\t|' ' ' \
        | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

diag_record_result() {
    diag_rr_check="$(diag_sanitize_text "${1:-unknown}")"
    diag_rr_result="${2:-SKIP}"
    diag_rr_details="$(diag_sanitize_text "${3:-}")"

    case "$diag_rr_result" in
        PASS|FAIL|SKIP) ;;
        *) diag_rr_result="FAIL" ;;
    esac

    printf '%s|%s|%s\n' \
        "$diag_rr_check" \
        "$diag_rr_result" \
        "$diag_rr_details" >>"$DIAG_RESULT_TABLE"

    case "$diag_rr_result" in
        PASS)
            log_pass "$diag_rr_check: $diag_rr_details"
            ;;
        FAIL)
            log_fail "$diag_rr_check: $diag_rr_details"
            ;;
        SKIP)
            log_skip "$diag_rr_check: $diag_rr_details"
            ;;
    esac
}

diag_result_count() {
    diag_rc_wanted="${1:-}"

    awk -F '|' -v wanted="$diag_rc_wanted" '
        $2 == wanted {
            count++
        }
        END {
            print count + 0
        }
    ' "$DIAG_RESULT_TABLE" 2>/dev/null
}

diag_print_summary() {
    diag_ps_passed="$(diag_result_count PASS)"
    diag_ps_failed="$(diag_result_count FAIL)"
    diag_ps_skipped="$(diag_result_count SKIP)"

    log_info "DIAG Validation Summary"
    printf '%s\n' "--------------------------------------------------------------------------------"
    printf '%-34s %-7s %s\n' "Check" "Result" "Details"
    printf '%s\n' "--------------------------------------------------------------------------------"

    while IFS='|' read -r diag_ps_check diag_ps_result diag_ps_details; do
        [ -n "$diag_ps_check" ] || continue

        printf '%-34s %-7s %s\n' \
            "$diag_ps_check" \
            "$diag_ps_result" \
            "$diag_ps_details"
    done <"$DIAG_RESULT_TABLE"

    printf '%s\n' "--------------------------------------------------------------------------------"
    printf 'Passed: %s Failed: %s Skipped: %s\n' \
        "$diag_ps_passed" \
        "$diag_ps_failed" \
        "$diag_ps_skipped"
}

diag_compute_overall_result() {
    diag_cor_core_status="${1:-SKIP}"
    diag_cor_failed="$(diag_result_count FAIL)"

    if [ "$diag_cor_failed" -gt 0 ]; then
        printf '%s\n' "FAIL"
    elif [ "$diag_cor_core_status" = "PASS" ]; then
        printf '%s\n' "PASS"
    else
        printf '%s\n' "SKIP"
    fi
}

diag_is_positive_integer() {
    case "${1:-}" in
        ''|*[!0-9]*)
            return 1
            ;;
        0)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

diag_is_boolean() {
    case "${1:-}" in
        0|1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

diag_shell_quote_arg() {
    diag_sqa_arg="${1:-}"

    case "$diag_sqa_arg" in
        "")
            printf "''"
            ;;
        *[!A-Za-z0-9_./:=,+%@#-]*)
            printf "'%s'" "$(printf '%s' "$diag_sqa_arg" | sed "s/'/'\\\\''/g")"
            ;;
        *)
            printf '%s' "$diag_sqa_arg"
            ;;
    esac
}

diag_log_command() {
    diag_lc_message=""

    for diag_lc_arg in "$@"; do
        diag_lc_quoted="$(diag_shell_quote_arg "$diag_lc_arg")"

        if [ -n "$diag_lc_message" ]; then
            diag_lc_message="$diag_lc_message $diag_lc_quoted"
        else
            diag_lc_message="$diag_lc_quoted"
        fi
    done

    log_info "RUN: $diag_lc_message"
}

# Execute a command with a portable watchdog. Returns 124 on timeout.
diag_run_with_timeout() {
    diag_rwt_timeout="${1:-5}"
    shift

    if ! diag_is_positive_integer "$diag_rwt_timeout"; then
        diag_rwt_timeout=5
    fi

    diag_rwt_tag="$(date +%s 2>/dev/null || echo 0)"
    diag_rwt_marker="${TMPDIR:-/tmp}/diag_timeout.$$.$diag_rwt_tag"
    rm -f "$diag_rwt_marker" 2>/dev/null || true

    "$@" &
    diag_rwt_pid=$!

    (
        sleep "$diag_rwt_timeout" 2>/dev/null || true

        if kill -0 "$diag_rwt_pid" 2>/dev/null; then
            echo 1 >"$diag_rwt_marker" 2>/dev/null || true
            kill -TERM "$diag_rwt_pid" 2>/dev/null || true
            sleep 1 2>/dev/null || true

            if kill -0 "$diag_rwt_pid" 2>/dev/null; then
                kill -KILL "$diag_rwt_pid" 2>/dev/null || true
            fi
        fi
    ) &
    diag_rwt_watchdog=$!

    wait "$diag_rwt_pid"
    diag_rwt_rc=$?

    kill "$diag_rwt_watchdog" 2>/dev/null || true
    wait "$diag_rwt_watchdog" 2>/dev/null || true

    if [ -f "$diag_rwt_marker" ]; then
        rm -f "$diag_rwt_marker" 2>/dev/null || true
        return 124
    fi

    rm -f "$diag_rwt_marker" 2>/dev/null || true
    return "$diag_rwt_rc"
}

diag_capture_help() {
    diag_ch_tool="${1:-}"
    diag_ch_file="${2:-}"

    [ -n "$diag_ch_tool" ] || return 1
    [ -n "$diag_ch_file" ] || return 1

    : >"$diag_ch_file"

    diag_run_with_timeout 5 "$diag_ch_tool" --help \
        >"$diag_ch_file" 2>&1 || true

    if [ ! -s "$diag_ch_file" ]; then
        diag_run_with_timeout 5 "$diag_ch_tool" -h \
            >"$diag_ch_file" 2>&1 || true
    fi

    [ -s "$diag_ch_file" ]
}

diag_help_supports_option() {
    diag_hso_file="${1:-}"
    diag_hso_option="${2:-}"

    [ -s "$diag_hso_file" ] || return 1
    [ -n "$diag_hso_option" ] || return 1

    grep -Eq -- \
        "(^|[[:space:],])${diag_hso_option}([[:space:],]|$)" \
        "$diag_hso_file"
}

diag_find_pids_by_name() {
    diag_fpn_name="${1:-}"
 
    [ -n "$diag_fpn_name" ] || return 0
 
    for diag_fpn_proc in /proc/[0-9]*; do
        [ -d "$diag_fpn_proc" ] || continue
 
        diag_fpn_pid="${diag_fpn_proc#/proc/}"
        diag_fpn_comm="$(cat "$diag_fpn_proc/comm" 2>/dev/null || true)"
 
        if [ "$diag_fpn_comm" = "$diag_fpn_name" ]; then
            printf '%s\n' "$diag_fpn_pid"
            continue
        fi
 
        diag_fpn_first="$(
            tr '\000' '\n' <"$diag_fpn_proc/cmdline" 2>/dev/null \
                | head -n 1
        )"
 
        [ -n "$diag_fpn_first" ] || continue
 
        # Do not use basename here. Process arguments may begin with '-',
        # which some basename implementations interpret as an option.
        diag_fpn_base="${diag_fpn_first##*/}"
 
        if [ "$diag_fpn_base" = "$diag_fpn_name" ]; then
            printf '%s\n' "$diag_fpn_pid"
        fi
    done
}

diag_pid_alive() {
    diag_pa_pid="${1:-}"

    [ -n "$diag_pa_pid" ] || return 1
    [ -r "/proc/$diag_pa_pid/status" ] || return 1

    diag_pa_state="$(
        awk '/^State:/ { print $2; exit }' \
            "/proc/$diag_pa_pid/status" 2>/dev/null || true
    )"

    [ "$diag_pa_state" = "Z" ] && return 1

    kill -0 "$diag_pa_pid" 2>/dev/null
}

diag_process_description() {
    diag_pd_pid="${1:-}"

    diag_pd_uid="$(
        awk '/^Uid:/ { print $2; exit }' \
            "/proc/$diag_pd_pid/status" 2>/dev/null || true
    )"

    diag_pd_cmd="$(
        tr '\000' ' ' \
            <"/proc/$diag_pd_pid/cmdline" 2>/dev/null || true
    )"

    printf 'pid=%s uid=%s cmd=%s\n' \
        "${diag_pd_pid:-unknown}" \
        "${diag_pd_uid:-unknown}" \
        "${diag_pd_cmd:-unknown}"
}

diag_get_process_option() {
    diag_gpo_pid="${1:-}"
    diag_gpo_option="${2:-}"
    diag_gpo_expect_value=0

    tr '\000' '\n' <"/proc/$diag_gpo_pid/cmdline" 2>/dev/null \
        | while IFS= read -r diag_gpo_arg; do
            if [ "$diag_gpo_expect_value" -eq 1 ]; then
                printf '%s\n' "$diag_gpo_arg"
                break
            fi

            if [ "$diag_gpo_arg" = "$diag_gpo_option" ]; then
                diag_gpo_expect_value=1
            fi
        done
}

diag_register_owned_pid() {
    diag_rop_pid="${1:-}"

    [ -n "$diag_rop_pid" ] || return 0

    case " $DIAG_OWNED_PIDS " in
        *" $diag_rop_pid "*)
            ;;
        *)
            DIAG_OWNED_PIDS="$DIAG_OWNED_PIDS $diag_rop_pid"
            ;;
    esac
}

diag_unregister_owned_pid() {
    diag_uop_target="${1:-}"
    diag_uop_remaining=""

    [ -n "$diag_uop_target" ] || return 0

    for diag_uop_pid in $DIAG_OWNED_PIDS; do
        [ "$diag_uop_pid" = "$diag_uop_target" ] && continue
        diag_uop_remaining="$diag_uop_remaining $diag_uop_pid"
    done

    DIAG_OWNED_PIDS="$diag_uop_remaining"
}

diag_wait_for_pid_exit() {
    diag_wpe_pid="${1:-}"
    diag_wpe_timeout="${2:-5}"
    diag_wpe_waited=0

    while diag_pid_alive "$diag_wpe_pid"; do
        if [ "$diag_wpe_waited" -ge "$diag_wpe_timeout" ]; then
            return 1
        fi

        sleep 1
        diag_wpe_waited=$((diag_wpe_waited + 1))
    done

    wait "$diag_wpe_pid" >/dev/null 2>&1 || true
    return 0
}

diag_stop_pid() {
    diag_sp_pid="${1:-}"
    diag_sp_timeout="${2:-10}"
 
    if ! diag_is_positive_integer "$diag_sp_timeout"; then
        diag_sp_timeout=10
    fi
 
    if ! diag_pid_alive "$diag_sp_pid"; then
        wait "$diag_sp_pid" >/dev/null 2>&1 || true
        diag_unregister_owned_pid "$diag_sp_pid"
        return 0
    fi
 
    # Prefer SIGINT because diag_mdlog normally performs its orderly
    # deinitialization through the interactive Ctrl+C shutdown path.
    kill -INT "$diag_sp_pid" 2>/dev/null || true
 
    if diag_wait_for_pid_exit "$diag_sp_pid" "$diag_sp_timeout"; then
        diag_unregister_owned_pid "$diag_sp_pid"
        return 0
    fi
 
    log_warn "PID $diag_sp_pid did not stop after INT; trying TERM"
    kill -TERM "$diag_sp_pid" 2>/dev/null || true
 
    if diag_wait_for_pid_exit "$diag_sp_pid" "$diag_sp_timeout"; then
        diag_unregister_owned_pid "$diag_sp_pid"
        return 2
    fi
 
    log_warn "PID $diag_sp_pid did not stop after TERM; using KILL"
    kill -KILL "$diag_sp_pid" 2>/dev/null || true
 
    if diag_wait_for_pid_exit "$diag_sp_pid" 2; then
        diag_unregister_owned_pid "$diag_sp_pid"
        return 3
    fi
 
    return 1
}

diag_stop_router_pid() {
    diag_srp_pid="${1:-}"
    diag_srp_timeout="${2:-5}"

    if ! diag_is_positive_integer "$diag_srp_timeout"; then
        diag_srp_timeout=5
    fi

    if ! diag_pid_alive "$diag_srp_pid"; then
        wait "$diag_srp_pid" >/dev/null 2>&1 || true
        diag_unregister_owned_pid "$diag_srp_pid"
        return 0
    fi

    kill -TERM "$diag_srp_pid" 2>/dev/null || true

    if diag_wait_for_pid_exit "$diag_srp_pid" "$diag_srp_timeout"; then
        diag_unregister_owned_pid "$diag_srp_pid"
        return 0
    fi

    log_warn "diag-router PID $diag_srp_pid did not stop after TERM; using KILL"
    kill -KILL "$diag_srp_pid" 2>/dev/null || true

    if diag_wait_for_pid_exit "$diag_srp_pid" 2; then
        diag_unregister_owned_pid "$diag_srp_pid"
        return 2
    fi

    return 1
}

diag_cleanup_owned_processes() {
    for diag_cop_pid in $DIAG_OWNED_PIDS; do
        diag_pid_alive "$diag_cop_pid" || continue
 
        if [ -n "${DIAG_ROUTER_PID:-}" ] && \
           [ "$diag_cop_pid" = "$DIAG_ROUTER_PID" ]; then
 
            log_info "Stopping owned diag-router PID $diag_cop_pid during cleanup"
 
            diag_stop_router_pid \
                "$diag_cop_pid" \
                "${DIAG_STOP_TIMEOUT_SECS:-5}" || true
        else
            log_info "Stopping owned DIAG process PID $diag_cop_pid during cleanup"
 
            diag_stop_pid \
                "$diag_cop_pid" \
                "${DIAG_STOP_TIMEOUT_SECS:-10}" || true
        fi
    done
}

diag_wait_for_log_pattern() {
    diag_wlp_file="${1:-}"
    diag_wlp_pattern="${2:-}"
    diag_wlp_timeout="${3:-10}"
    diag_wlp_elapsed=0

    while [ "$diag_wlp_elapsed" -lt "$diag_wlp_timeout" ]; do
        if [ -f "$diag_wlp_file" ] && \
           grep -Eq "$diag_wlp_pattern" "$diag_wlp_file" 2>/dev/null; then
            return 0
        fi

        sleep 1
        diag_wlp_elapsed=$((diag_wlp_elapsed + 1))
    done

    return 1
}

diag_wait_pid_duration() {
    diag_wpd_pid="${1:-}"
    diag_wpd_duration="${2:-1}"
    diag_wpd_elapsed=0

    while [ "$diag_wpd_elapsed" -lt "$diag_wpd_duration" ]; do
        diag_pid_alive "$diag_wpd_pid" || return 1
        sleep 1
        diag_wpd_elapsed=$((diag_wpd_elapsed + 1))
    done

    diag_pid_alive "$diag_wpd_pid"
}

diag_log_tail() {
    diag_lt_prefix="${1:-diag}"
    diag_lt_file="${2:-}"
    diag_lt_lines="${3:-60}"

    [ -f "$diag_lt_file" ] || return 0

    log_info "[DEBUG] Tail of $diag_lt_file:"

    tail -n "$diag_lt_lines" "$diag_lt_file" 2>/dev/null \
        | while IFS= read -r diag_lt_line; do
            [ -n "$diag_lt_line" ] && \
                log_info "[$diag_lt_prefix] $diag_lt_line"
        done
}

diag_nonempty_file_count() {
    diag_nfc_root="${1:-}"

    if [ ! -d "$diag_nfc_root" ]; then
        printf '%s\n' 0
        return 0
    fi

    find "$diag_nfc_root" -type f -size +0c 2>/dev/null \
        | wc -l \
        | awk '{ print $1 + 0 }'
}

diag_first_child_directory() {
    diag_fcd_root="${1:-}"

    [ -d "$diag_fcd_root" ] || return 1

    for diag_fcd_entry in "$diag_fcd_root"/*; do
        [ -d "$diag_fcd_entry" ] || continue
        printf '%s\n' "$diag_fcd_entry"
        return 0
    done

    return 1
}

diag_extract_output_dir_from_log() {
    diag_eod_file="${1:-}"

    [ -f "$diag_eod_file" ] || return 1

    sed -n \
        's/.*Output dirs \([^[:space:]]*\)[[:space:]].*/\1/p' \
        "$diag_eod_file" \
        | tail -n 1
}

diag_inventory_tools() {
    diag_it_help_dir="$DIAG_RUN_DIR/tool_help"
    mkdir -p "$diag_it_help_dir" || return 1

    DIAG_MDLOG_PATH="$(command -v diag_mdlog 2>/dev/null || true)"

    if [ -z "$DIAG_MDLOG_PATH" ]; then
        diag_record_result \
            "diag_mdlog binary" \
            "SKIP" \
            "diag_mdlog is not installed"
    else
        DIAG_MDLOG_HELP_FILE="$diag_it_help_dir/diag_mdlog_help.txt"

        if diag_capture_help "$DIAG_MDLOG_PATH" "$DIAG_MDLOG_HELP_FILE"; then
            diag_record_result \
                "diag_mdlog binary" \
                "PASS" \
                "path=$DIAG_MDLOG_PATH help=$DIAG_MDLOG_HELP_FILE"
        else
            diag_record_result \
                "diag_mdlog binary" \
                "PASS" \
                "path=$DIAG_MDLOG_PATH; help output unavailable"
        fi
    fi

    for diag_it_tool in \
        diag-router \
        diag_klog \
        diag_socket_log \
        diag_uart_log \
        diag_callback_sample \
        diag_dci_sample; do

        diag_it_path="$(command -v "$diag_it_tool" 2>/dev/null || true)"
        diag_it_help_file="$diag_it_help_dir/${diag_it_tool}_help.txt"

        if [ -z "$diag_it_path" ]; then
            diag_record_result \
                "$diag_it_tool capability" \
                "SKIP" \
                "binary not installed"
            continue
        fi

        if [ "${DIAG_PROBE_OPTIONAL_HELP:-0}" = "1" ]; then
            if diag_capture_help "$diag_it_path" "$diag_it_help_file"; then
                diag_record_result \
                    "$diag_it_tool capability" \
                    "PASS" \
                    "path=$diag_it_path help=$diag_it_help_file"
            else
                diag_record_result \
                    "$diag_it_tool capability" \
                    "PASS" \
                    "path=$diag_it_path; help output unavailable"
            fi
        else
            diag_record_result \
                "$diag_it_tool capability" \
                "PASS" \
                "path=$diag_it_path; optional help probe disabled"
        fi
    done

    [ -n "$DIAG_MDLOG_PATH" ]
}

diag_validate_router_socket() {
    diag_vrs_router_path="$(command -v diag-router 2>/dev/null || true)"
    diag_vrs_router_log="$DIAG_RUN_DIR/diag_router.log"
    diag_vrs_router_pid="$(diag_find_active_router_pid || true)"
    diag_vrs_router_ready=0
 
    if [ -n "$diag_vrs_router_pid" ]; then
        DIAG_ROUTER_PID="$diag_vrs_router_pid"
        DIAG_ROUTER_LOG=""
        DIAG_ROUTER_OWNED=0
        diag_vrs_router_ready=1
 
        diag_vrs_description="$(
            diag_process_description "$diag_vrs_router_pid"
        )"
 
        diag_record_result \
            "diag-router process" \
            "PASS" \
            "existing router: $diag_vrs_description"
    else
        if [ -z "$diag_vrs_router_path" ]; then
            diag_record_result \
                "diag-router process" \
                "FAIL" \
                "diag-router binary is not installed"
 
            diag_record_result \
                "DIAG transport readiness" \
                "FAIL" \
                "router is unavailable"
 
            return 1
        fi
 
        log_info "No existing diag-router process found"
 
        if diag_start_router_process \
            "initial DIAG validation" \
            "$diag_vrs_router_log"; then
 
            diag_vrs_router_ready=1
 
            diag_vrs_description="$(
                diag_process_description "$DIAG_ROUTER_PID"
            )"
 
            diag_record_result \
                "diag-router process" \
                "PASS" \
                "started owned router: $diag_vrs_description log=$DIAG_ROUTER_LOG"
        else
            diag_record_result \
                "diag-router process" \
                "FAIL" \
                "diag-router exited during startup; log=$diag_vrs_router_log"
 
            diag_log_tail \
                "diag-router" \
                "$diag_vrs_router_log" \
                80
 
            diag_record_result \
                "DIAG transport readiness" \
                "FAIL" \
                "router startup failed"
 
            return 1
        fi
    fi
 
    diag_vrs_socket=""
    diag_vrs_socket_waited=0
 
    while [ "$diag_vrs_socket_waited" -lt 5 ]; do
        if [ -r /proc/net/unix ]; then
            diag_vrs_socket="$(
                grep -i 'diag' /proc/net/unix 2>/dev/null \
                    | head -n 1
            )"
        fi
 
        [ -n "$diag_vrs_socket" ] && break
 
        if ! diag_pid_alive "$DIAG_ROUTER_PID"; then
            diag_vrs_router_ready=0
            break
        fi
 
        sleep 1
        diag_vrs_socket_waited=$((diag_vrs_socket_waited + 1))
    done
 
    if [ "$diag_vrs_router_ready" -ne 1 ]; then
        diag_record_result \
            "DIAG transport readiness" \
            "FAIL" \
            "diag-router terminated while transport readiness was being checked"
 
        diag_log_tail \
            "diag-router" \
            "$DIAG_ROUTER_LOG" \
            80
 
        return 1
    fi
 
    if [ -n "$diag_vrs_socket" ]; then
        diag_record_result \
            "DIAG transport readiness" \
            "PASS" \
            "named DIAG Unix socket found: $diag_vrs_socket"
    elif [ "$DIAG_ROUTER_OWNED" -eq 1 ]; then
        diag_record_result \
            "DIAG transport readiness" \
            "PASS" \
            "owned diag-router is active; this implementation does not expose a named socket in /proc/net/unix"
    else
        diag_record_result \
            "DIAG transport readiness" \
            "PASS" \
            "existing diag-router is active; this implementation does not expose a named socket in /proc/net/unix"
    fi
 
    return 0
}

diag_validate_requested_configuration() {
    DIAG_EXPLICIT_MASK=0
    diag_vrc_error=0
 
    if ! diag_is_positive_integer "$DIAG_DURATION_SECS"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_DURATION_SECS must be a positive integer"
        diag_vrc_error=1
    fi
 
    if ! diag_is_positive_integer "$DIAG_NRT_DURATION_SECS"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_NRT_DURATION_SECS must be a positive integer"
        diag_vrc_error=1
    fi
 
    if ! diag_is_positive_integer "$DIAG_STARTUP_TIMEOUT_SECS"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_STARTUP_TIMEOUT_SECS must be a positive integer"
        diag_vrc_error=1
    fi
 
    if ! diag_is_positive_integer "$DIAG_STOP_TIMEOUT_SECS"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_STOP_TIMEOUT_SECS must be a positive integer"
        diag_vrc_error=1
    fi
 
    if ! diag_is_positive_integer "$DIAG_FILE_SIZE"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_FILE_SIZE must be a positive integer"
        diag_vrc_error=1
    fi
 
    if ! diag_is_positive_integer "$DIAG_FILE_COUNT"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_FILE_COUNT must be a positive integer"
        diag_vrc_error=1
    fi
 
    if ! diag_is_boolean "$DIAG_TEST_NONREALTIME"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_TEST_NONREALTIME must be 0 or 1"
        diag_vrc_error=1
    fi
 
    if ! diag_is_boolean "$DIAG_KEEP_ARTIFACTS"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_KEEP_ARTIFACTS must be 0 or 1"
        diag_vrc_error=1
    fi
 
    if ! diag_is_boolean "$DIAG_PROBE_OPTIONAL_HELP"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_PROBE_OPTIONAL_HELP must be 0 or 1"
        diag_vrc_error=1
    fi
 
    if ! diag_is_boolean "$DIAG_QMDL2_V2"; then
        diag_record_result \
            "DIAG configuration" \
            "FAIL" \
            "DIAG_QMDL2_V2 must be 0 or 1"
        diag_vrc_error=1
    fi
 
    if [ -n "$DIAG_MASK_FILE" ] && [ -n "$DIAG_MASK_LIST" ]; then
        diag_record_result \
            "Mask configuration" \
            "FAIL" \
            "set only one of DIAG_MASK_FILE or DIAG_MASK_LIST"
        diag_vrc_error=1
    elif [ -n "$DIAG_MASK_FILE" ]; then
        DIAG_EXPLICIT_MASK=1
 
        if [ ! -r "$DIAG_MASK_FILE" ]; then
            diag_record_result \
                "Mask configuration" \
                "FAIL" \
                "mask file is not readable: $DIAG_MASK_FILE"
            diag_vrc_error=1
        elif ! diag_help_supports_option \
            "$DIAG_MDLOG_HELP_FILE" \
            "-f"; then
 
            diag_record_result \
                "Mask configuration" \
                "FAIL" \
                "diag_mdlog does not advertise -f support"
            diag_vrc_error=1
        else
            diag_record_result \
                "Mask configuration" \
                "PASS" \
                "using explicit mask file $DIAG_MASK_FILE"
        fi
    elif [ -n "$DIAG_MASK_LIST" ]; then
        DIAG_EXPLICIT_MASK=1
 
        if [ ! -r "$DIAG_MASK_LIST" ]; then
            diag_record_result \
                "Mask configuration" \
                "FAIL" \
                "mask list is not readable: $DIAG_MASK_LIST"
            diag_vrc_error=1
        elif ! diag_help_supports_option \
            "$DIAG_MDLOG_HELP_FILE" \
            "-l"; then
 
            diag_record_result \
                "Mask configuration" \
                "FAIL" \
                "diag_mdlog does not advertise -l support"
            diag_vrc_error=1
        else
            diag_record_result \
                "Mask configuration" \
                "PASS" \
                "using explicit mask list $DIAG_MASK_LIST"
        fi
    else
        diag_record_result \
            "Mask configuration" \
            "PASS" \
            "default or previously configured device masks selected"
    fi
 
    diag_vrc_requested=""
 
    for diag_vrc_pair in \
        "-p|$DIAG_PERIPHERAL_MASK" \
        "-j|$DIAG_PROCESSOR_MASK" \
        "-g|$DIAG_USERPD_MASK" \
        "-q|$DIAG_QDSS_MASK" \
        "-t|$DIAG_TX_MODE" \
        "-x|$DIAG_BUFFER_PERIPHERAL_MASK" \
        "-y|$DIAG_ETR_BUFFER_SIZE"; do
 
        diag_vrc_option="${diag_vrc_pair%%|*}"
        diag_vrc_value="${diag_vrc_pair#*|}"
 
        [ -n "$diag_vrc_value" ] || continue
 
        if ! diag_help_supports_option \
            "$DIAG_MDLOG_HELP_FILE" \
            "$diag_vrc_option"; then
 
            diag_record_result \
                "Requested mdlog options" \
                "FAIL" \
                "$diag_vrc_option was requested but is not advertised by diag_mdlog"
            diag_vrc_error=1
        else
            diag_vrc_requested="$diag_vrc_requested $diag_vrc_option=$diag_vrc_value"
        fi
    done
 
    if [ "$DIAG_QMDL2_V2" = "1" ]; then
        if ! diag_help_supports_option \
            "$DIAG_MDLOG_HELP_FILE" \
            "-u"; then
 
            diag_record_result \
                "Requested mdlog options" \
                "FAIL" \
                "-u was requested but is not advertised by diag_mdlog"
            diag_vrc_error=1
        else
            diag_vrc_requested="$diag_vrc_requested -u"
        fi
    fi
 
    if [ -n "$diag_vrc_requested" ]; then
        diag_record_result \
            "Requested mdlog options" \
            "PASS" \
            "$diag_vrc_requested"
    elif [ "$diag_vrc_error" -eq 0 ]; then
        diag_record_result \
            "Requested mdlog options" \
            "PASS" \
            "default diag_mdlog option set selected"
    fi
 
    [ "$diag_vrc_error" -eq 0 ]
}

diag_start_router_process() {
    diag_srp_context="${1:-DIAG}"
    diag_srp_log="${2:-$DIAG_RUN_DIR/diag_router.log}"
    diag_srp_path="$(command -v diag-router 2>/dev/null || true)"

    DIAG_ROUTER_PID=""
    DIAG_ROUTER_LOG="$diag_srp_log"
    DIAG_ROUTER_OWNED=0

    [ -n "$diag_srp_path" ] || return 1

    : >"$diag_srp_log" || return 1

    log_info "Starting owned diag-router for $diag_srp_context"
    diag_log_command "$diag_srp_path"

    "$diag_srp_path" >"$diag_srp_log" 2>&1 &
    diag_srp_pid=$!

    diag_register_owned_pid "$diag_srp_pid"

    diag_srp_waited=0

    while [ "$diag_srp_waited" -lt 5 ]; do
        if diag_pid_alive "$diag_srp_pid"; then
            DIAG_ROUTER_PID="$diag_srp_pid"
            DIAG_ROUTER_LOG="$diag_srp_log"
            DIAG_ROUTER_OWNED=1
            return 0
        fi

        sleep 1
        diag_srp_waited=$((diag_srp_waited + 1))
    done

    wait "$diag_srp_pid" >/dev/null 2>&1 || true
    diag_unregister_owned_pid "$diag_srp_pid"

    return 1
}

diag_find_active_router_pid() {
    diag_farp_pids="$(diag_find_pids_by_name diag-router)"

    for diag_farp_pid in $diag_farp_pids; do
        if diag_pid_alive "$diag_farp_pid"; then
            printf '%s\n' "$diag_farp_pid"
            return 0
        fi
    done

    return 1
}

diag_ensure_router_for_session() {
    diag_erfs_label="${1:-DIAG}"
    diag_erfs_active_pid="$(diag_find_active_router_pid || true)"

    if [ -n "$diag_erfs_active_pid" ]; then
        DIAG_ROUTER_PID="$diag_erfs_active_pid"
        return 0
    fi

    if [ -n "${DIAG_ROUTER_PID:-}" ]; then
        diag_record_result \
            "$diag_erfs_label router continuity" \
            "FAIL" \
            "diag-router PID $DIAG_ROUTER_PID terminated unexpectedly after the previous DIAG session"
    else
        diag_record_result \
            "$diag_erfs_label router continuity" \
            "FAIL" \
            "no active diag-router process was found"
    fi

    diag_erfs_log="$DIAG_RUN_DIR/diag_router_recovery.log"

    if diag_start_router_process \
        "$diag_erfs_label recovery" \
        "$diag_erfs_log"; then

        diag_record_result \
            "$diag_erfs_label router recovery" \
            "PASS" \
            "restarted owned diag-router pid=$DIAG_ROUTER_PID log=$diag_erfs_log"

        sleep 2
        return 0
    fi

    diag_record_result \
        "$diag_erfs_label router recovery" \
        "FAIL" \
        "unable to restart diag-router; log=$diag_erfs_log"

    diag_log_tail \
        "diag-router-recovery" \
        "$diag_erfs_log" \
        80

    return 1
}

diag_start_mdlog_session() {
    diag_sms_mode="${1:-normal}"
    diag_sms_output_root="${2:-}"
    diag_sms_log_file="${3:-}"

    DIAG_LAST_PID=""
    DIAG_LAST_LOG="$diag_sms_log_file"
    DIAG_LAST_OUTPUT_ROOT="$diag_sms_output_root"
    DIAG_LAST_OUTPUT_DIR=""

    mkdir -p "$diag_sms_output_root" || return 1
    chmod 0777 "$diag_sms_output_root" 2>/dev/null || return 1
    : >"$diag_sms_log_file" || return 1

    set -- "$DIAG_MDLOG_PATH" \
        -o "$diag_sms_output_root" \
        -s "$DIAG_FILE_SIZE" \
        -n "$DIAG_FILE_COUNT"

    if [ -n "$DIAG_MASK_FILE" ]; then
        set -- "$@" -f "$DIAG_MASK_FILE"
    elif [ -n "$DIAG_MASK_LIST" ]; then
        set -- "$@" -l "$DIAG_MASK_LIST"
    fi

    if [ -n "$DIAG_PERIPHERAL_MASK" ]; then
        set -- "$@" -p "$DIAG_PERIPHERAL_MASK"
    fi

    if [ -n "$DIAG_PROCESSOR_MASK" ]; then
        set -- "$@" -j "$DIAG_PROCESSOR_MASK"
    fi

    if [ -n "$DIAG_USERPD_MASK" ]; then
        set -- "$@" -g "$DIAG_USERPD_MASK"
    fi

    if [ -n "$DIAG_QDSS_MASK" ]; then
        set -- "$@" -q "$DIAG_QDSS_MASK"
    fi

    if [ -n "$DIAG_TX_MODE" ]; then
        set -- "$@" -t "$DIAG_TX_MODE"
    fi

    if [ -n "$DIAG_BUFFER_PERIPHERAL_MASK" ]; then
        set -- "$@" -x "$DIAG_BUFFER_PERIPHERAL_MASK"
    fi

    if [ -n "$DIAG_ETR_BUFFER_SIZE" ]; then
        set -- "$@" -y "$DIAG_ETR_BUFFER_SIZE"
    fi

    if [ "$DIAG_QMDL2_V2" = "1" ]; then
        set -- "$@" -u
    fi

    if [ "$diag_sms_mode" = "nonrealtime" ]; then
        set -- "$@" -b
    fi

    log_info "Starting owned diag_mdlog session: mode=$diag_sms_mode output=$diag_sms_output_root size=$DIAG_FILE_SIZE count=$DIAG_FILE_COUNT"
    diag_log_command "$@"

    "$@" >"$diag_sms_log_file" 2>&1 &
    DIAG_LAST_PID=$!

    diag_register_owned_pid "$DIAG_LAST_PID"

    return 0
}

diag_validate_started_session() {
    diag_vss_label="${1:-Normal}"
    diag_vss_duration="${2:-5}"
    diag_vss_require_data="${3:-1}"
    diag_vss_pid="$DIAG_LAST_PID"
    diag_vss_log="$DIAG_LAST_LOG"
    diag_vss_output_root="$DIAG_LAST_OUTPUT_ROOT"
    diag_vss_prefix="$(printf '%s' "$diag_vss_label" | tr ' ' '-')"
 
    sleep 1
 
    if ! diag_pid_alive "$diag_vss_pid"; then
        if grep -qiE \
            'Session for peripheral mask .* is active with PID' \
            "$diag_vss_log" 2>/dev/null; then
 
            diag_vss_conflict="$(
                grep -iE \
                    'Session for peripheral mask .* is active with PID' \
                    "$diag_vss_log" 2>/dev/null \
                    | tail -n 1
            )"
 
            diag_record_result \
                "$diag_vss_label logging startup" \
                "SKIP" \
                "session conflict: $diag_vss_conflict"
 
            DIAG_SESSION_CONFLICT=1
 
            diag_log_tail \
                "$diag_vss_prefix" \
                "$diag_vss_log" \
                60
 
            return 2
        fi
 
        diag_record_result \
            "$diag_vss_label logging startup" \
            "FAIL" \
            "diag_mdlog exited during startup; log=$diag_vss_log"
 
        diag_log_tail \
            "$diag_vss_prefix" \
            "$diag_vss_log" \
            80
 
        return 1
    fi
 
    if grep -qiE \
        'Diag_LSM_Init.*(fail|error)|failed to connect to socket|unable to connect to socket|segmentation fault|fatal error' \
        "$diag_vss_log" 2>/dev/null; then
 
        diag_record_result \
            "$diag_vss_label logging startup" \
            "FAIL" \
            "fatal DIAG startup error detected; log=$diag_vss_log"
 
        diag_log_tail \
            "$diag_vss_prefix" \
            "$diag_vss_log" \
            80
 
        diag_stop_pid \
            "$diag_vss_pid" \
            "$DIAG_STOP_TIMEOUT_SECS" || true
 
        return 1
    fi
 
    if ! diag_wait_pid_duration \
        "$diag_vss_pid" \
        "$diag_vss_duration"; then
 
        diag_record_result \
            "$diag_vss_label logging startup" \
            "FAIL" \
            "PID $diag_vss_pid exited before ${diag_vss_duration}s"
 
        diag_log_tail \
            "$diag_vss_prefix" \
            "$diag_vss_log" \
            80
 
        diag_stop_pid \
            "$diag_vss_pid" \
            "$DIAG_STOP_TIMEOUT_SECS" || true
 
        return 1
    fi
 
    DIAG_SESSION_VALIDATED=1
 
    # Stop the process before evaluating its complete log. diag_mdlog may
    # buffer stdout while running and flush initialization messages at exit.
    diag_stop_pid \
        "$diag_vss_pid" \
        "$DIAG_STOP_TIMEOUT_SECS"
 
    diag_vss_stop_rc=$?
 
    case "$diag_vss_stop_rc" in
        0)
            diag_record_result \
                "$diag_vss_label clean shutdown" \
                "PASS" \
                "owned PID $diag_vss_pid stopped through the orderly INT path"
            ;;
        2)
            diag_record_result \
                "$diag_vss_label clean shutdown" \
                "PASS" \
                "owned PID $diag_vss_pid stopped after TERM fallback"
            ;;
        3)
            diag_record_result \
                "$diag_vss_label clean shutdown" \
                "FAIL" \
                "owned PID $diag_vss_pid required KILL"
            ;;
        *)
            diag_record_result \
                "$diag_vss_label clean shutdown" \
                "FAIL" \
                "unable to stop owned PID $diag_vss_pid"
            ;;
    esac
 
    # Allow redirected output to be fully flushed.
    sleep 1
 
    if grep -qiE \
        'Diag_LSM_Init.*(fail|error)|failed to connect to socket|unable to connect to socket|segmentation fault|fatal error' \
        "$diag_vss_log" 2>/dev/null; then
 
        diag_record_result \
            "$diag_vss_label logging startup" \
            "FAIL" \
            "fatal DIAG error detected in the final process log"
 
        diag_log_tail \
            "$diag_vss_prefix" \
            "$diag_vss_log" \
            80
 
        return 1
    fi
 
    DIAG_LAST_OUTPUT_DIR="$(
        diag_extract_output_dir_from_log "$diag_vss_log" || true
    )"
 
    if [ -n "$DIAG_LAST_OUTPUT_DIR" ] && \
       [ -d "$DIAG_LAST_OUTPUT_DIR" ]; then
 
        diag_record_result \
            "$diag_vss_label output directory" \
            "PASS" \
            "$DIAG_LAST_OUTPUT_DIR"
    else
        DIAG_LAST_OUTPUT_DIR="$(
            diag_first_child_directory "$diag_vss_output_root" || true
        )"
 
        if [ -n "$DIAG_LAST_OUTPUT_DIR" ] && \
           [ -d "$DIAG_LAST_OUTPUT_DIR" ]; then
 
            diag_record_result \
                "$diag_vss_label output directory" \
                "PASS" \
                "$DIAG_LAST_OUTPUT_DIR"
        elif find "$diag_vss_output_root" -type f 2>/dev/null \
            | grep -q .; then
 
            diag_record_result \
                "$diag_vss_label output directory" \
                "PASS" \
                "diag_mdlog wrote directly under $diag_vss_output_root"
        elif [ -d "$diag_vss_output_root" ]; then
            diag_record_result \
                "$diag_vss_label output directory" \
                "SKIP" \
                "output root exists, but no DIAG output was detected"
        else
            diag_record_result \
                "$diag_vss_label output directory" \
                "FAIL" \
                "output directory was not created"
        fi
    fi
 
    diag_vss_nonempty="$(
        diag_nonempty_file_count "$diag_vss_output_root"
    )"
 
    if [ "$diag_vss_nonempty" -gt 0 ]; then
        diag_record_result \
            "$diag_vss_label log data" \
            "PASS" \
            "$diag_vss_nonempty non-empty file(s) created"
    elif [ "$DIAG_EXPLICIT_MASK" -eq 1 ] && \
         [ "$diag_vss_require_data" -eq 1 ]; then
 
        diag_record_result \
            "$diag_vss_label log data" \
            "FAIL" \
            "explicit mask was supplied but no non-empty log file was created"
    else
        diag_record_result \
            "$diag_vss_label log data" \
            "SKIP" \
            "no non-empty DIAG log file was observed"
    fi
 
    # LSM initialization evidence.
    if grep -qiE \
        'Diag_LSM_Init succeeded|Diag_LSM_Init: done' \
        "$diag_vss_log" 2>/dev/null; then
 
        diag_record_result \
            "$diag_vss_label LSM initialization" \
            "PASS" \
            "DIAG LSM initialization confirmed in process log"
    elif [ "$diag_vss_nonempty" -gt 0 ]; then
        diag_record_result \
            "$diag_vss_label LSM initialization" \
            "PASS" \
            "validated indirectly by a stable session and non-empty DIAG output"
    else
        diag_record_result \
            "$diag_vss_label LSM initialization" \
            "SKIP" \
            "LSM initialization could not be confirmed"
    fi
 
    # Socket or DIAG transport connection evidence.
    if grep -qiE \
        'successfully connected to socket' \
        "$diag_vss_log" 2>/dev/null; then
 
        diag_record_result \
            "$diag_vss_label socket connection" \
            "PASS" \
            "diag_mdlog connected to the DIAG socket"
    elif [ -r /proc/net/unix ] && \
         grep -qi 'diag' /proc/net/unix 2>/dev/null; then
 
        diag_record_result \
            "$diag_vss_label socket connection" \
            "PASS" \
            "named DIAG Unix socket is visible"
    elif [ "$diag_vss_nonempty" -gt 0 ]; then
        diag_record_result \
            "$diag_vss_label socket connection" \
            "PASS" \
            "DIAG transport validated indirectly by non-empty logging output"
    else
        diag_record_result \
            "$diag_vss_label socket connection" \
            "SKIP" \
            "DIAG transport connection could not be confirmed"
    fi
 
    # Logging-switch evidence.
    if grep -qiE \
        'logging switched' \
        "$diag_vss_log" 2>/dev/null; then
 
        diag_record_result \
            "$diag_vss_label logging switch" \
            "PASS" \
            "peripheral logging switch confirmed in process log"
    elif [ "$diag_vss_nonempty" -gt 0 ]; then
        diag_record_result \
            "$diag_vss_label logging switch" \
            "PASS" \
            "validated indirectly because DIAG data was captured"
    else
        diag_record_result \
            "$diag_vss_label logging switch" \
            "SKIP" \
            "logging-switch operation could not be confirmed"
    fi
 
    diag_record_result \
        "$diag_vss_label logging startup" \
        "PASS" \
        "PID $diag_vss_pid remained active for ${diag_vss_duration}s"
 
    # Mask validation.
    if [ "$DIAG_EXPLICIT_MASK" -eq 1 ] && \
       grep -qiE \
           "can't open mask file|Error reading mask file|No mask files have been successfully read" \
           "$diag_vss_log" 2>/dev/null; then
 
        diag_record_result \
            "$diag_vss_label mask application" \
            "FAIL" \
            "explicit mask could not be read; see $diag_vss_log"
    elif [ "$DIAG_EXPLICIT_MASK" -eq 1 ]; then
        diag_record_result \
            "$diag_vss_label mask application" \
            "PASS" \
            "explicit mask was accepted without a mask-read error"
    elif [ "$diag_vss_nonempty" -gt 0 ]; then
        diag_record_result \
            "$diag_vss_label mask application" \
            "PASS" \
            "default or previously configured masks produced non-empty DIAG data"
    else
        diag_record_result \
            "$diag_vss_label mask application" \
            "SKIP" \
            "no explicit mask supplied and no DIAG data was observed"
    fi
 
    return 0
}

diag_validate_existing_mdlog_session() {
    diag_vems_pids="$(diag_find_pids_by_name diag_mdlog)"

    [ -n "$diag_vems_pids" ] || return 1

    diag_vems_details=""
    diag_vems_first_pid=""

    for diag_vems_pid in $diag_vems_pids; do
        diag_pid_alive "$diag_vems_pid" || continue

        if [ -z "$diag_vems_first_pid" ]; then
            diag_vems_first_pid="$diag_vems_pid"
        fi

        diag_vems_desc="$(diag_process_description "$diag_vems_pid")"

        if [ -n "$diag_vems_details" ]; then
            diag_vems_details="$diag_vems_details; $diag_vems_desc"
        else
            diag_vems_details="$diag_vems_desc"
        fi
    done

    [ -n "$diag_vems_first_pid" ] || return 1

    diag_record_result \
        "Existing mdlog session" \
        "PASS" \
        "$diag_vems_details"

    diag_record_result \
        "Owned normal session" \
        "SKIP" \
        "not started because an existing diag_mdlog session is active"

    diag_record_result \
        "Non-real-time session" \
        "SKIP" \
        "not started because an existing diag_mdlog session is active"

    diag_vems_output="$(
        diag_get_process_option "$diag_vems_first_pid" -o \
            | head -n 1
    )"

    if [ -n "$diag_vems_output" ] && \
       [ -d "$diag_vems_output" ]; then

        diag_vems_count="$(
            diag_nonempty_file_count "$diag_vems_output"
        )"

        if [ "$diag_vems_count" -gt 0 ]; then
            diag_record_result \
                "Existing session output" \
                "PASS" \
                "$diag_vems_count non-empty file(s) under $diag_vems_output"
        else
            diag_record_result \
                "Existing session output" \
                "SKIP" \
                "output path exists but no non-empty file was observed: $diag_vems_output"
        fi
    else
        diag_record_result \
            "Existing session output" \
            "SKIP" \
            "existing process output path could not be determined"
    fi

    DIAG_SESSION_VALIDATED=1
    return 0
}

diag_validate_normal_session() {
    diag_vns_output="$DIAG_RUN_DIR/normal_output"
    diag_vns_log="$DIAG_RUN_DIR/normal_diag_mdlog.log"

    if ! diag_start_mdlog_session \
        normal \
        "$diag_vns_output" \
        "$diag_vns_log"; then

        diag_record_result \
            "Normal logging startup" \
            "FAIL" \
            "unable to prepare or start diag_mdlog"
        return 1
    fi

    diag_validate_started_session \
        "Normal" \
        "$DIAG_DURATION_SECS" \
        1
}

diag_validate_nonrealtime_session() {
    if [ "${DIAG_TEST_NONREALTIME:-1}" != "1" ]; then
        diag_record_result \
            "Non-real-time session" \
            "SKIP" \
            "disabled by DIAG_TEST_NONREALTIME"

        return 0
    fi

    if ! diag_help_supports_option \
        "$DIAG_MDLOG_HELP_FILE" \
        "-b"; then

        diag_record_result \
            "Non-real-time session" \
            "SKIP" \
            "diag_mdlog does not advertise -b support"

        return 0
    fi

    diag_vnrs_existing="$(diag_find_pids_by_name diag_mdlog)"

    if [ -n "$diag_vnrs_existing" ]; then
        diag_record_result \
            "Non-real-time session" \
            "SKIP" \
            "another diag_mdlog session is active: $diag_vnrs_existing"

        return 0
    fi

    if ! diag_ensure_router_for_session "Non-real-time"; then
        diag_record_result \
            "Non-real-time logging startup" \
            "FAIL" \
            "diag-router is unavailable and recovery failed"

        return 1
    fi

    diag_vnrs_output="$DIAG_RUN_DIR/nonrealtime_output"
    diag_vnrs_log="$DIAG_RUN_DIR/nonrealtime_diag_mdlog.log"

    if ! diag_start_mdlog_session \
        nonrealtime \
        "$diag_vnrs_output" \
        "$diag_vnrs_log"; then

        diag_record_result \
            "Non-real-time logging startup" \
            "FAIL" \
            "unable to prepare or start diag_mdlog -b"

        return 1
    fi

    diag_validate_started_session \
        "Non-real-time" \
        "$DIAG_NRT_DURATION_SECS" \
        0
}
