#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

MRV_LAST_CMD_PID=""
MRV_LAST_CMD_ELAPSED="0"
MRV_LAST_TIMEOUT_DIR=""
MRV_PROFILE_REASON=""

mrv_reset_profile_vars() {
  PROFILE_NAME=""
  PROFILE_DESCRIPTION=""
  MODULE_NAME=""
  MODULE_LOAD_CMD=""
  MODULE_UNLOAD_CMD=""
  MODULE_RELOAD_SUPPORTED="yes"
  PROFILE_MODE_DEFAULT="basic"
  PROFILE_REQUIRED_CMDS=""
  PROFILE_SERVICES=""
  PROFILE_PROC_PATTERNS=""
  PROFILE_DEVICE_PATTERNS=""
  PROFILE_SYSFS_PATTERNS=""
  PROFILE_SELECTED_MODE=""
}

mrv_module_lsmod_name() {
  printf '%s\n' "$1" | tr '-' '_'
}

mrv_module_loaded() {
  name="$(mrv_module_lsmod_name "$1")"
  is_module_loaded "$name"
}

mrv_module_builtin() {
  if [ -f "/lib/modules/$(uname -r)/modules.builtin" ]; then
    mod_pat="$(printf '%s\n' "$1" | sed 's/_/[-_]/g')"
    grep -Eq "/${mod_pat}(\\.ko(\\.[^.]+)*)?$" "/lib/modules/$(uname -r)/modules.builtin" 2>/dev/null
    return $?
  fi
  return 1
}

mrv_wait_module_state() {
  want="$1"
  name="$2"
  timeout_s="$3"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    if [ "$want" = "present" ]; then
      if mrv_module_loaded "$name"; then
        return 0
      fi
    else
      if ! mrv_module_loaded "$name"; then
        return 0
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if [ "$want" = "present" ]; then
    mrv_module_loaded "$name"
    return $?
  fi

  if mrv_module_loaded "$name"; then
    return 1
  fi
  return 0
}

mrv_capture_patterns() {
  patterns="$1"
  outfile="$2"

  : > "$outfile"

  if [ -z "$patterns" ]; then
    return 0
  fi

  # shellcheck disable=SC2086
  set -- $patterns
  for pat in "$@"; do
    found=0
    # shellcheck disable=SC2086
    for path in $pat; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        found=1
        printf 'PATH: %s\n' "$path" >> "$outfile"
        ls -ld "$path" >> "$outfile" 2>&1 || true
      fi
    done
    if [ "$found" -eq 0 ] 2>/dev/null; then
      printf 'PATH: %s (not present)\n' "$pat" >> "$outfile"
    fi
  done
}

mrv_capture_services() {
  services="$1"
  outfile="$2"

  : > "$outfile"

  if [ -z "$services" ]; then
    printf 'No profile services defined\n' >> "$outfile"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'systemctl not available\n' >> "$outfile"
    return 0
  fi

  # shellcheck disable=SC2086
  set -- $services
  for svc in "$@"; do
    printf '===== %s =====\n' "$svc" >> "$outfile"
    systemctl status "$svc" --no-pager >> "$outfile" 2>&1 || true
    if command -v journalctl >/dev/null 2>&1; then
      printf '\n----- journalctl -u %s -----\n' "$svc" >> "$outfile"
      journalctl -u "$svc" --no-pager -n 200 >> "$outfile" 2>&1 || true
    fi
  done
}

mrv_capture_module_state() {
  outdir="$1"
  mkdir -p "$outdir"

  {
    printf 'profile=%s\n' "${PROFILE_NAME:-unknown}"
    printf 'description=%s\n' "${PROFILE_DESCRIPTION:-unknown}"
    printf 'module=%s\n' "${MODULE_NAME:-unknown}"
    printf 'mode=%s\n' "${PROFILE_SELECTED_MODE:-unknown}"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'date=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
  } > "$outdir/state.txt"

  sys_mod="$(mrv_module_lsmod_name "$MODULE_NAME")"

  {
    printf 'Module-focused lsmod view for %s\n' "$sys_mod"
    lsmod 2>/dev/null | awk -v mod="$sys_mod" '
      NR == 1 { print; next }
      $1 == mod { found=1; print }
      END {
        if (!found) {
          printf "module %s not present in lsmod\n", mod
        }
      }
    '
  } > "$outdir/lsmod.log" 2>&1 || true

  modinfo "$MODULE_NAME" > "$outdir/modinfo.log" 2>&1 || true
  ps -ef > "$outdir/ps.log" 2>&1 || true
  dmesg > "$outdir/dmesg.log" 2>&1 || true

  if [ -d "/sys/module/$sys_mod" ]; then
    find "/sys/module/$sys_mod" -maxdepth 3 -print > "$outdir/sys_module_tree.log" 2>&1 || true
    if [ -d "/sys/module/$sys_mod/holders" ]; then
      ls -la "/sys/module/$sys_mod/holders" > "$outdir/holders.log" 2>&1 || true
    fi
  else
    printf '/sys/module/%s not present\n' "$sys_mod" > "$outdir/holders.log"
  fi

  mrv_capture_services "$PROFILE_SERVICES" "$outdir/services.log"
  mrv_capture_patterns "$PROFILE_DEVICE_PATTERNS" "$outdir/devices.log"
  mrv_capture_patterns "$PROFILE_SYSFS_PATTERNS" "$outdir/profile_sysfs.log"

  if command -v journalctl >/dev/null 2>&1; then
    journalctl -b --no-pager -n 300 > "$outdir/journal.log" 2>&1 || true
  fi
}

mrv_capture_pid_timeout_snapshot() {
  pid="$1"
  outdir="$2"

  mkdir -p "$outdir"

  if [ -d "/proc/$pid" ]; then
    cat "/proc/$pid/status" > "$outdir/proc_status.log" 2>&1 || true
    cat "/proc/$pid/wchan" > "$outdir/proc_wchan.log" 2>&1 || true
    cat "/proc/$pid/stack" > "$outdir/proc_stack.log" 2>&1 || true
    ps -T -p "$pid" > "$outdir/ps_threads.log" 2>&1 || true
  fi
}

mrv_exec_with_timeout() {
  timeout_s="$1"
  logfile="$2"
  shift 2
  cmd="$*"
  elapsed=0

  : > "$logfile"
  printf 'CMD: %s\n' "$cmd" >> "$logfile"

  sh -c "$cmd" >> "$logfile" 2>&1 &
  cmd_pid=$!
  MRV_LAST_CMD_PID="$cmd_pid"
  MRV_LAST_CMD_ELAPSED=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_s" ] 2>/dev/null; then
      MRV_LAST_CMD_ELAPSED="$elapsed"

      printf 'TIMEOUT: command exceeded %ss (pid=%s)\n' "$timeout_s" "$cmd_pid" >> "$logfile"

      if [ -n "$MRV_LAST_TIMEOUT_DIR" ]; then
        mrv_capture_pid_timeout_snapshot "$cmd_pid" "$MRV_LAST_TIMEOUT_DIR"
      fi

      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 2

      if kill -0 "$cmd_pid" 2>/dev/null; then
        printf 'TIMEOUT: pid %s ignored SIGTERM, sending SIGKILL\n' "$cmd_pid" >> "$logfile"
        kill -KILL "$cmd_pid" 2>/dev/null || true
        sleep 1
      fi

      if kill -0 "$cmd_pid" 2>/dev/null; then
        printf 'TIMEOUT: pid %s still present after SIGKILL (likely stuck in kernel)\n' "$cmd_pid" >> "$logfile"
      fi

      return 124
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$cmd_pid"
  rc=$?
  MRV_LAST_CMD_ELAPSED="$elapsed"
  return "$rc"
}

mrv_capture_hang_evidence() {
  phase="$1"
  outdir="$2"

  mkdir -p "$outdir"
  mrv_capture_module_state "$outdir"

  if [ "$ENABLE_SYSRQ_HANG_DUMP" -eq 1 ] 2>/dev/null; then
    if [ -w /proc/sysrq-trigger ]; then
      printf 'Triggered sysrq-t and sysrq-w\n' > "$outdir/sysrq_actions.log"
      echo t > /proc/sysrq-trigger 2>/dev/null || true
      echo w > /proc/sysrq-trigger 2>/dev/null || true
      dmesg > "$outdir/dmesg_after_sysrq.log" 2>&1 || true
    fi
  fi

  if command -v fuser >/dev/null 2>&1; then
    : > "$outdir/fuser.log"
    # shellcheck disable=SC2086
    set -- $PROFILE_DEVICE_PATTERNS
    for pat in "$@"; do
      # shellcheck disable=SC2086
      for path in $pat; do
        if [ -e "$path" ] || [ -L "$path" ]; then
          printf '===== %s =====\n' "$path" >> "$outdir/fuser.log"
          fuser -vm "$path" >> "$outdir/fuser.log" 2>&1 || true
        fi
      done
    done
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof > "$outdir/lsof.log" 2>&1 || true
  fi

  {
    printf 'phase=%s\n' "$phase"
    printf 'pid=%s\n' "$MRV_LAST_CMD_PID"
    printf 'elapsed=%s\n' "$MRV_LAST_CMD_ELAPSED"
  } > "$outdir/timeout_summary.log"
}

mrv_profile_override_defined() {
  fn_name="$1"
  command -v "$fn_name" >/dev/null 2>&1
}

module_reload_service_known() {
  svc="$1"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  systemctl list-unit-files "$svc" >/dev/null 2>&1
}

module_reload_service_state_value() {
  svc="$1"
  prop="$2"

  val="$(systemctl show -p "$prop" --value "$svc" 2>/dev/null || true)"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  else
    printf 'unknown\n'
  fi
}

module_reload_list_pids_by_pattern() {
  proc_pat="$1"

  ps -eo pid=,args= 2>/dev/null | while IFS= read -r line; do
    line_trim="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//')"
    [ -n "$line_trim" ] || continue

    pid="${line_trim%% *}"
    cmd="${line_trim#"$pid"}"
    cmd="$(printf '%s\n' "$cmd" | sed 's/^[[:space:]]*//')"

    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue

    case "$cmd" in
      *"$proc_pat"*)
        printf '%s\n' "$pid"
        ;;
    esac
  done
}

module_reload_proc_running_pattern() {
  proc_pat="$1"
  pids="$(module_reload_list_pids_by_pattern "$proc_pat")"

  if [ -n "$pids" ]; then
    return 0
  fi
  return 1
}

module_reload_signal_pattern() {
  proc_pat="$1"
  sig="$2"
  log_tag="${3:-module-reload}"
  pids="$(module_reload_list_pids_by_pattern "$proc_pat")"

  for pid in $pids; do
    if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
      log_info "[$log_tag] sending SIG${sig} to pid=$pid pattern=$proc_pat"
      kill "-$sig" "$pid" >/dev/null 2>&1 || true
    fi
  done

  return 0
}

module_reload_wait_no_procs_patterns() {
  proc_patterns="$1"
  timeout_s="${2:-10}"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    found=0

    for proc_pat in $proc_patterns; do
      if module_reload_proc_running_pattern "$proc_pat"; then
        found=1
        break
      fi
    done

    if [ "$found" -eq 0 ]; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  for proc_pat in $proc_patterns; do
    if module_reload_proc_running_pattern "$proc_pat"; then
      return 1
    fi
  done

  return 0
}

module_reload_log_service_process_summary() {
  services="$1"
  proc_patterns="$2"
  log_tag="${3:-module-reload}"

  if command -v systemctl >/dev/null 2>&1; then
    for svc in $services; do
      if module_reload_service_known "$svc"; then
        svc_active="$(module_reload_service_state_value "$svc" "ActiveState")"
        svc_sub="$(module_reload_service_state_value "$svc" "SubState")"
        svc_pid="$(module_reload_service_state_value "$svc" "MainPID")"
        log_info "[$log_tag] $svc state=${svc_active}/${svc_sub} mainpid=${svc_pid}"
      fi
    done
  fi

  ps -eo pid=,args= 2>/dev/null | while IFS= read -r line; do
    line_trim="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//')"
    [ -n "$line_trim" ] || continue

    pid="${line_trim%% *}"
    cmd="${line_trim#"$pid"}"
    cmd="$(printf '%s\n' "$cmd" | sed 's/^[[:space:]]*//')"

    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue

    for proc_pat in $proc_patterns; do
      case "$cmd" in
        *"$proc_pat"*)
          log_info "[$log_tag] proc pid=$pid cmd=$cmd"
          break
          ;;
      esac
    done
  done
}

module_reload_wait_services_active() {
  services="$1"
  timeout_s="${2:-15}"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    all_ok=1

    for svc in $services; do
      if module_reload_service_known "$svc"; then
        if ! systemctl is-active --quiet "$svc"; then
          all_ok=0
          break
        fi
      fi
    done

    if [ "$all_ok" -eq 1 ]; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      if ! systemctl is-active --quiet "$svc"; then
        return 1
      fi
    fi
  done

  return 0
}

module_reload_wait_services_inactive() {
  services="$1"
  timeout_s="${2:-15}"
  elapsed=0

  while [ "$elapsed" -lt "$timeout_s" ] 2>/dev/null; do
    all_ok=1

    for svc in $services; do
      if module_reload_service_known "$svc"; then
        if systemctl is-active --quiet "$svc"; then
          all_ok=0
          break
        fi
      fi
    done

    if [ "$all_ok" -eq 1 ]; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      if systemctl is-active --quiet "$svc"; then
        return 1
      fi
    fi
  done

  return 0
}

module_reload_start_services() {
  services="$1"
  timeout_s="${2:-15}"
  log_tag="${3:-module-reload}"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] start: unmasking and starting $svc"
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl reset-failed "$svc" >/dev/null 2>&1 || true
      systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done

  module_reload_wait_services_active "$services" "$timeout_s"
}

module_reload_stop_mask_kill_services() {
  services="$1"
  proc_patterns="$2"
  timeout_s="${3:-20}"
  log_tag="${4:-module-reload}"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] quiesce: stopping $svc"
      systemctl stop "$svc" >/dev/null 2>&1 || true
      log_info "[$log_tag] quiesce: masking $svc"
      systemctl mask "$svc" >/dev/null 2>&1 || true
      log_info "[$log_tag] quiesce: killing remaining $svc cgroup processes"
      systemctl kill --kill-who=all "$svc" >/dev/null 2>&1 || true
    fi
  done

  for proc_pat in $proc_patterns; do
    module_reload_signal_pattern "$proc_pat" TERM "$log_tag"
  done

  sleep 2

  if ! module_reload_wait_no_procs_patterns "$proc_patterns" 5; then
    log_warn "[$log_tag] quiesce: TERM was not enough, sending SIGKILL to remaining processes"
    for proc_pat in $proc_patterns; do
      module_reload_signal_pattern "$proc_pat" KILL "$log_tag"
    done
    sleep 1
  fi

  if ! module_reload_wait_services_inactive "$services" "$timeout_s"; then
    return 1
  fi

  if ! module_reload_wait_no_procs_patterns "$proc_patterns" 2; then
    return 1
  fi

  return 0
}

module_reload_restore_services() {
  services="$1"
  timeout_s="${2:-15}"
  log_tag="${3:-module-reload}"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      log_info "[$log_tag] finalize: restoring $svc"
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl reset-failed "$svc" >/dev/null 2>&1 || true
      systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done

  module_reload_wait_services_active "$services" "$timeout_s"
}

module_reload_dump_service_status() {
  services="$1"
  svc_log="$2"

  [ -n "$svc_log" ] || return 0
  : > "$svc_log"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  for svc in $services; do
    if module_reload_service_known "$svc"; then
      printf '===== %s =====\n' "$svc" >> "$svc_log"
      systemctl status "$svc" --no-pager >> "$svc_log" 2>&1 || true
    fi
  done

  return 0
}

module_reload_profile_prepare() {
  profile_root="$1"
  : "${profile_root:=}"

  if mrv_profile_override_defined profile_prepare; then
    profile_prepare "$profile_root"
    return $?
  fi

  return 0
}

module_reload_profile_warmup() {
  iter_dir="$1"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_warmup; then
    profile_warmup "$iter_dir"
    return $?
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  case "$PROFILE_SELECTED_MODE" in
    basic)
      return 0
      ;;
    daemon_lifecycle|service_rebind)
      if ! module_reload_start_services "$PROFILE_SERVICES" 15 "$PROFILE_NAME"; then
        module_reload_log_service_process_summary "$PROFILE_SERVICES" "$PROFILE_PROC_PATTERNS" "$PROFILE_NAME"
        log_error "[$PROFILE_NAME] warmup: services failed to become active"
        return 1
      fi
      ;;
    *)
      log_warn "[$PROFILE_NAME] unknown mode '$PROFILE_SELECTED_MODE', continuing without warmup actions"
      ;;
  esac

  return 0
}

module_reload_profile_quiesce() {
  iter_dir="$1"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_quiesce; then
    profile_quiesce "$iter_dir"
    return $?
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  case "$PROFILE_SELECTED_MODE" in
    basic)
      return 0
      ;;
    daemon_lifecycle|service_rebind)
      if ! module_reload_stop_mask_kill_services "$PROFILE_SERVICES" "$PROFILE_PROC_PATTERNS" 20 "$PROFILE_NAME"; then
        module_reload_log_service_process_summary "$PROFILE_SERVICES" "$PROFILE_PROC_PATTERNS" "$PROFILE_NAME"
        log_error "[$PROFILE_NAME] quiesce: services/processes did not fully stop"
        return 1
      fi
      ;;
    *)
      log_warn "[$PROFILE_NAME] unknown mode '$PROFILE_SELECTED_MODE', continuing without quiesce actions"
      ;;
  esac

  return 0
}

module_reload_profile_post_unload() {
  iter_dir="$1"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_post_unload; then
    profile_post_unload "$iter_dir"
    return $?
  fi

  return 0
}

module_reload_profile_post_load() {
  iter_dir="$1"
  svc_log="$iter_dir/post_load_services.log"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_post_load; then
    profile_post_load "$iter_dir"
    return $?
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  case "$PROFILE_SELECTED_MODE" in
    basic)
      return 0
      ;;
    daemon_lifecycle|service_rebind)
      if ! module_reload_start_services "$PROFILE_SERVICES" 15 "$PROFILE_NAME"; then
        module_reload_log_service_process_summary "$PROFILE_SERVICES" "$PROFILE_PROC_PATTERNS" "$PROFILE_NAME"
        log_error "[$PROFILE_NAME] post-load: services failed to become active after reload"
        return 1
      fi

      module_reload_dump_service_status "$PROFILE_SERVICES" "$svc_log"
      ;;
    *)
      log_warn "[$PROFILE_NAME] unknown mode '$PROFILE_SELECTED_MODE', continuing without post-load actions"
      ;;
  esac

  return 0
}

module_reload_profile_smoke() {
  iter_dir="$1"
  : "${iter_dir:=}"

  if mrv_profile_override_defined profile_smoke; then
    profile_smoke "$iter_dir"
    return $?
  fi

  return 0
}

module_reload_profile_finalize() {
  profile_root="$1"
  : "${profile_root:=}"

  if mrv_profile_override_defined profile_finalize; then
    profile_finalize "$profile_root"
    return $?
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  if ! module_reload_restore_services "$PROFILE_SERVICES" 15 "$PROFILE_NAME"; then
    log_error "[$PROFILE_NAME] finalize: failed to restore services"
    return 1
  fi

  return 0
}

mrv_profile_check() {
  requested_mode="$1"

  if [ -z "$PROFILE_NAME" ] || [ -z "$MODULE_NAME" ]; then
    MRV_PROFILE_REASON="profile missing PROFILE_NAME or MODULE_NAME"
    return 2
  fi

  if [ "${MODULE_RELOAD_SUPPORTED:-yes}" != "yes" ]; then
    MRV_PROFILE_REASON="profile marks module as non-reloadable"
    return 2
  fi

  if mrv_module_builtin "$MODULE_NAME"; then
    MRV_PROFILE_REASON="module is built-in and cannot be unloaded"
    return 2
  fi

  if ! modinfo "$MODULE_NAME" >/dev/null 2>&1; then
    if ! mrv_module_loaded "$MODULE_NAME"; then
      MRV_PROFILE_REASON="module not present on image"
      return 2
    fi
  fi

  if ! command -v modprobe >/dev/null 2>&1; then
    MRV_PROFILE_REASON="modprobe not available"
    return 2
  fi

  if ! command -v rmmod >/dev/null 2>&1; then
    MRV_PROFILE_REASON="rmmod not available"
    return 2
  fi

  required="${PROFILE_REQUIRED_CMDS:-}"
  if [ -n "$required" ]; then
    # shellcheck disable=SC2086
    set -- $required
    for req in "$@"; do
      if ! command -v "$req" >/dev/null 2>&1; then
        MRV_PROFILE_REASON="required command missing: $req"
        return 2
      fi
    done
  fi

  MODULE_LOAD_CMD="${MODULE_LOAD_CMD:-modprobe $MODULE_NAME}"
  MODULE_UNLOAD_CMD="${MODULE_UNLOAD_CMD:-rmmod $MODULE_NAME}"
  PROFILE_SELECTED_MODE="${requested_mode:-${PROFILE_MODE_DEFAULT:-basic}}"

  return 0
}

mrv_post_unload_validate() {
  if ! mrv_wait_module_state absent "$MODULE_NAME" "$TIMEOUT_SETTLE"; then
    log_fail "[$PROFILE_NAME] module still present after unload settle timeout"
    return 1
  fi
  return 0
}

mrv_post_load_validate() {
  if ! mrv_wait_module_state present "$MODULE_NAME" "$TIMEOUT_SETTLE"; then
    log_fail "[$PROFILE_NAME] module did not reappear after load settle timeout"
    return 1
  fi
  return 0
}

mrv_run_iteration() {
  iter="$1"
  iter_dir="$RESULT_ROOT/$PROFILE_NAME/iter_$(printf '%02d' "$iter")"
  preload_log="$iter_dir/preload.log"
  unload_log="$iter_dir/unload.log"
  load_log="$iter_dir/load.log"
  unload_elapsed=0
  load_elapsed=0

  mkdir -p "$iter_dir"

  if ! mrv_module_loaded "$MODULE_NAME"; then
    log_info "[$PROFILE_NAME] module not loaded before iteration $iter, creating baseline loaded state"
    MRV_LAST_TIMEOUT_DIR="$iter_dir/preload_timeout"
    mrv_exec_with_timeout "$TIMEOUT_LOAD" "$preload_log" "$MODULE_LOAD_CMD"
    preload_rc=$?
    if [ "$preload_rc" -ne 0 ]; then
      log_fail "[$PROFILE_NAME] failed to create baseline loaded state before iteration $iter (rc=$preload_rc)"
      log_info "[$PROFILE_NAME] preload log: $preload_log"
      return 1
    fi
    if ! mrv_post_load_validate; then
      log_info "[$PROFILE_NAME] baseline post-load validation failed"
      return 1
    fi
  fi

  if ! module_reload_profile_warmup "$iter_dir"; then
    log_fail "[$PROFILE_NAME] warmup stage failed in iteration $iter"
    return 1
  fi

  mrv_capture_module_state "$iter_dir/pre_state"

  if ! module_reload_profile_quiesce "$iter_dir"; then
    log_fail "[$PROFILE_NAME] quiesce stage failed in iteration $iter"
    return 1
  fi

  log_info "[$PROFILE_NAME] iter $iter/$ITERATIONS exec: $MODULE_UNLOAD_CMD"
  MRV_LAST_TIMEOUT_DIR="$iter_dir/unload_timeout"
  mrv_exec_with_timeout "$TIMEOUT_UNLOAD" "$unload_log" "$MODULE_UNLOAD_CMD"
  unload_rc=$?
  unload_elapsed="$MRV_LAST_CMD_ELAPSED"

  if [ "$unload_rc" -eq 124 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS unload timed out after ${unload_elapsed}s (pid=$MRV_LAST_CMD_PID)"
    log_info "[$PROFILE_NAME] unload timeout log: $unload_log"
    log_info "[$PROFILE_NAME] collecting hang evidence in: $iter_dir/hang_evidence"
    mrv_capture_hang_evidence unload "$iter_dir/hang_evidence"
    log_fail "[$PROFILE_NAME] hang evidence captured; failing iteration $iter/$ITERATIONS"
    return 1
  fi

  if [ "$unload_rc" -ne 0 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS unload failed (rc=$unload_rc)"
    log_info "[$PROFILE_NAME] unload log: $unload_log"
    mrv_capture_module_state "$iter_dir/unload_failure_state"
    return 1
  fi

  if ! mrv_post_unload_validate; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS post-unload validation failed"
    mrv_capture_module_state "$iter_dir/post_unload_invalid_state"
    return 1
  fi

  mrv_capture_module_state "$iter_dir/post_unload_state"

  if ! module_reload_profile_post_unload "$iter_dir"; then
    log_fail "[$PROFILE_NAME] post-unload stage failed in iteration $iter"
    return 1
  fi

  log_info "[$PROFILE_NAME] iter $iter/$ITERATIONS exec: $MODULE_LOAD_CMD"
  MRV_LAST_TIMEOUT_DIR="$iter_dir/load_timeout"
  mrv_exec_with_timeout "$TIMEOUT_LOAD" "$load_log" "$MODULE_LOAD_CMD"
  load_rc=$?
  load_elapsed="$MRV_LAST_CMD_ELAPSED"

  if [ "$load_rc" -eq 124 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS load timed out after ${load_elapsed}s (pid=$MRV_LAST_CMD_PID)"
    log_info "[$PROFILE_NAME] load timeout log: $load_log"
    log_info "[$PROFILE_NAME] collecting hang evidence in: $iter_dir/load_hang_evidence"
    mrv_capture_hang_evidence load "$iter_dir/load_hang_evidence"
    log_fail "[$PROFILE_NAME] hang evidence captured, failing iteration $iter/$ITERATIONS"
    return 1
  fi

  if [ "$load_rc" -ne 0 ]; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS load failed (rc=$load_rc)"
    log_info "[$PROFILE_NAME] load log: $load_log"
    mrv_capture_module_state "$iter_dir/load_failure_state"
    return 1
  fi

  if ! mrv_post_load_validate; then
    log_fail "[$PROFILE_NAME] iter $iter/$ITERATIONS post-load validation failed"
    mrv_capture_module_state "$iter_dir/post_load_invalid_state"
    return 1
  fi

  if ! module_reload_profile_post_load "$iter_dir"; then
    log_fail "[$PROFILE_NAME] post-load stage failed in iteration $iter"
    mrv_capture_module_state "$iter_dir/post_load_hook_failure_state"
    return 1
  fi

  if ! module_reload_profile_smoke "$iter_dir"; then
    log_fail "[$PROFILE_NAME] smoke stage failed in iteration $iter"
    mrv_capture_module_state "$iter_dir/smoke_failure_state"
    return 1
  fi

  mrv_capture_module_state "$iter_dir/post_load_state"

  if command -v diff >/dev/null 2>&1; then
    diff -u "$iter_dir/pre_state/dmesg.log" "$iter_dir/post_load_state/dmesg.log" > "$iter_dir/dmesg.diff" 2>&1 || true
  fi

  {
    printf 'iter=%s\n' "$iter"
    printf 'unload_elapsed=%s\n' "$unload_elapsed"
    printf 'load_elapsed=%s\n' "$load_elapsed"
  } > "$iter_dir/iteration_metrics.log"

  log_pass "[$PROFILE_NAME] iteration $iter/$ITERATIONS passed"
  return 0
}

mrv_run_one_profile() (
  profile_file="$1"
  requested_mode="$2"

  mrv_reset_profile_vars

  # shellcheck disable=SC1090
  . "$profile_file"

  mrv_profile_check "$requested_mode"
  check_rc=$?
  if [ "$check_rc" -eq 2 ]; then
    log_skip "[$(basename "$profile_file" .profile)] SKIP - $MRV_PROFILE_REASON"
    exit 2
  fi
  if [ "$check_rc" -ne 0 ]; then
    log_fail "[$(basename "$profile_file" .profile)] FAIL - profile validation error"
    exit 1
  fi

  profile_root="$RESULT_ROOT/$PROFILE_NAME"
  mkdir -p "$profile_root"

  {
    printf 'profile=%s\n' "$PROFILE_NAME"
    printf 'description=%s\n' "${PROFILE_DESCRIPTION:-unknown}"
    printf 'module=%s\n' "$MODULE_NAME"
    printf 'mode=%s\n' "$PROFILE_SELECTED_MODE"
  } > "$profile_root/profile_info.txt"

  log_info "[$PROFILE_NAME] module=$MODULE_NAME mode=$PROFILE_SELECTED_MODE iterations=$ITERATIONS"

  if ! module_reload_profile_prepare "$profile_root"; then
    log_fail "[$PROFILE_NAME] prepare stage failed"
    exit 1
  fi

  iter=1
  while [ "$iter" -le "$ITERATIONS" ] 2>/dev/null; do
    if ! mrv_run_iteration "$iter"; then
      module_reload_profile_finalize "$profile_root" >/dev/null 2>&1 || true
      exit 1
    fi
    iter=$((iter + 1))
  done

  if ! module_reload_profile_finalize "$profile_root"; then
    log_fail "[$PROFILE_NAME] finalize stage failed"
    exit 1
  fi

  exit 0
)

mrv_resolve_profiles() {
  target_module="$1"
  profile_dir="$2"
  profile_list_file="$3"

  if [ -n "$target_module" ]; then
    candidate="$profile_dir/$target_module.profile"
    if [ ! -f "$candidate" ]; then
      log_error "Profile not found: $candidate"
      return 1
    fi
    printf '%s\n' "$candidate"
    return 0
  fi

  if [ -f "$profile_list_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|'#'*) continue ;;
      esac
      candidate="$profile_dir/$line.profile"
      if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
      else
        log_warn "Enabled profile listed but missing: $candidate"
      fi
    done < "$profile_list_file"
    return 0
  fi

  for candidate in "$profile_dir"/*.profile; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
    fi
  done

  return 0
}
