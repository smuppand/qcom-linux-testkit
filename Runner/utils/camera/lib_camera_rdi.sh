#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
# Common helpers for Camera_RDI_FrameCapture.

# This file is sourced by:
# Runner/suites/Multimedia/Camera/Camera_RDI_FrameCapture/run.sh
#
# Keep this file limited to RDI-specific helpers:
# - format preparation/restoration
# - V4L2 pixfmt to media-bus fmt conversion
# - yavta timeout/capture handling
# - stream-control cleanup
# - retry/result tracking helpers

# shellcheck disable=SC2317
# Functions in this sourced helper are invoked by run.sh.

camera_rdi_trim() {
  printf '%s' "${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

camera_rdi_current_mbus_fmt() {
  printf '%s\n' "${MEDIA_CTL_V_LIST:-}" \
    | sed -n 's/.*fmt:\([^/]]*\)\/.*/\1/p' \
    | head -n 1
}

camera_rdi_video_fmt_to_mbus_fmt() {
  v4l2_fmt="$(camera_rdi_trim "$1")"
  current_mbus="$(camera_rdi_current_mbus_fmt)"

  if [ -z "$v4l2_fmt" ]; then
    printf '%s\n' "${current_mbus:-auto}"
    return 0
  fi

  # If caller already passed an mbus-style format, keep it.
  case "$v4l2_fmt" in
    *_1X[0-9]*|*_2X[0-9]*)
      printf '%s\n' "$v4l2_fmt"
      return 0
      ;;
  esac

  # Generic RAW Bayer rule:
  # SGRBG10P -> SGRBG10_1X10
  # SGRBG10 -> SGRBG10_1X10
  # SRGGB12P -> SRGGB12_1X12
  # SBGGR8 -> SBGGR8_1X8
  bayer_mbus="$(
    printf '%s\n' "$v4l2_fmt" | awk '
      {
        f = $1
        sub(/P$/, "", f)

        if (length(f) < 6) {
          exit
        }

        prefix = substr(f, 1, 1)
        order = substr(f, 2, 4)
        bits = substr(f, 6)

        if (prefix != "S") {
          exit
        }

        if (order != "RGGB" && order != "GRBG" && order != "GBRG" && order != "BGGR") {
          exit
        }

        if (bits != "8" && bits != "10" && bits != "12" && bits != "14" && bits != "16") {
          exit
        }

        printf "S%s%s_1X%s\n", order, bits, bits
      }
    '
  )"

  if [ -n "$bayer_mbus" ]; then
    printf '%s\n' "$bayer_mbus"
    return 0
  fi

  # Small generic YUV mappings. These are not sensor-specific.
  case "$v4l2_fmt" in
    UYVY) printf '%s\n' "UYVY8_1X16"; return 0 ;;
    YUYV) printf '%s\n' "YUYV8_1X16"; return 0 ;;
    YVYU) printf '%s\n' "YVYU8_1X16"; return 0 ;;
    VYUY) printf '%s\n' "VYUY8_1X16"; return 0 ;;
  esac

  # For formats like NV12, there may not be a direct sensor pad mbus code.
  # Keep the discovered media-bus format instead of guessing wrongly.
  if [ -n "$current_mbus" ]; then
    printf '%s\n' "$current_mbus"
  else
    printf '%s\n' "$v4l2_fmt"
  fi
}

camera_rdi_prepare_format_iteration() {
  fmt_override="$1"
  default_yavta_fmt="$2"

  CAMERA_RDI_SAVE_MEDIA_CTL_V_LIST="${MEDIA_CTL_V_LIST:-}"
  CAMERA_RDI_SAVE_YAVTA_W="${YAVTA_W:-}"
  CAMERA_RDI_SAVE_YAVTA_H="${YAVTA_H:-}"

  fmt_override="$(camera_rdi_trim "$fmt_override")"
  default_yavta_fmt="$(camera_rdi_trim "$default_yavta_fmt")"

  TARGET_FORMAT="$fmt_override"
  [ -n "$TARGET_FORMAT" ] || TARGET_FORMAT="$default_yavta_fmt"

  PAD_MBUS_FMT="$(camera_rdi_video_fmt_to_mbus_fmt "$TARGET_FORMAT")"
  [ -n "$PAD_MBUS_FMT" ] || PAD_MBUS_FMT="$(camera_rdi_current_mbus_fmt)"
  [ -n "$PAD_MBUS_FMT" ] || PAD_MBUS_FMT="auto"

  # Keep the video node format as V4L2 pixfmt, but configure pads with mbus fmt.
  if [ "$PAD_MBUS_FMT" != "auto" ]; then
    MEDIA_CTL_V_LIST="$(
      printf '%s\n' "${MEDIA_CTL_V_LIST:-}" \
        | sed -E "s/fmt:[^/]+\//fmt:${PAD_MBUS_FMT}\//g"
    )"
  fi

  export TARGET_FORMAT PAD_MBUS_FMT MEDIA_CTL_V_LIST
}

camera_rdi_restore_format_iteration() {
  if [ -n "${CAMERA_RDI_SAVE_MEDIA_CTL_V_LIST+x}" ]; then
    MEDIA_CTL_V_LIST="$CAMERA_RDI_SAVE_MEDIA_CTL_V_LIST"
  fi

  if [ -n "${CAMERA_RDI_SAVE_YAVTA_W+x}" ]; then
    YAVTA_W="$CAMERA_RDI_SAVE_YAVTA_W"
  fi

  if [ -n "${CAMERA_RDI_SAVE_YAVTA_H+x}" ]; then
    YAVTA_H="$CAMERA_RDI_SAVE_YAVTA_H"
  fi

  unset CAMERA_RDI_SAVE_MEDIA_CTL_V_LIST
  unset CAMERA_RDI_SAVE_YAVTA_W
  unset CAMERA_RDI_SAVE_YAVTA_H

  export MEDIA_CTL_V_LIST YAVTA_W YAVTA_H
}

camera_rdi_shell_quote_arg() {
  arg="${1:-}"

  case "$arg" in
    "")
      printf "''"
      return 0
      ;;
    *[!A-Za-z0-9_./:=,+%@#-]*)
      printf "'%s'" "$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")"
      return 0
      ;;
    *)
      printf '%s' "$arg"
      return 0
      ;;
  esac
}

camera_rdi_log_cmd() {
  msg=""

  for arg in "$@"; do
    qarg="$(camera_rdi_shell_quote_arg "$arg")"

    if [ -n "$msg" ]; then
      msg="$msg $qarg"
    else
      msg="$qarg"
    fi
  done

  log_info "RUN: $msg"
}

camera_rdi_timeout_cmd() {
  timeout_secs="$1"
  shift

  case "$timeout_secs" in
    ''|*[!0-9]*)
      timeout_secs=45
      ;;
  esac

  if [ "$timeout_secs" -lt 1 ] 2>/dev/null; then
    timeout_secs=45
  fi

  # Use our own watchdog instead of external timeout because BusyBox/coreutils
  # timeout options differ across images.
  timeout_tag="$(date +%s 2>/dev/null || echo 0)"
  timed_out_file="${TMPDIR:-/tmp}/camera_rdi_timeout.$$.$timeout_tag"
  rm -f "$timed_out_file" 2>/dev/null || true

  "$@" &
  cmd_pid=$!

  (
    sleep "$timeout_secs" 2>/dev/null || true

    if kill -0 "$cmd_pid" 2>/dev/null; then
      echo "1" >"$timed_out_file" 2>/dev/null || true
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 3 2>/dev/null || true

      if kill -0 "$cmd_pid" 2>/dev/null; then
        kill -KILL "$cmd_pid" 2>/dev/null || true
      fi
    fi
  ) &
  watchdog_pid=$!

  wait "$cmd_pid"
  rc=$?

  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ -f "$timed_out_file" ]; then
    rm -f "$timed_out_file" 2>/dev/null || true
    return 124
  fi

  rm -f "$timed_out_file" 2>/dev/null || true
  return "$rc"
}

camera_rdi_exit_if_interrupted() {
  rc="$1"

  case "$rc" in
    130|131|143)
      log_warn "Interrupted by user or signal, stopping ${TESTNAME:-Camera_RDI_FrameCapture}"
      echo "${TESTNAME:-Camera_RDI_FrameCapture} FAIL" >"${RES_FILE:-./Camera_RDI_FrameCapture.res}" 2>/dev/null || true
      exit 1
      ;;
  esac

  return 0
}

camera_rdi_reset_media_graph() {
  media_node="$1"

  [ -n "$media_node" ] || return 0

  log_info " media-ctl -d $media_node -r"
  media-ctl -d "$media_node" -r >/dev/null 2>&1 || true
  sleep 0.1

  return 0
}

camera_rdi_begin_result_tracking() {
  CAMERA_RDI_SEEN_CAPTURE_FAIL=0
  CAMERA_RDI_SEEN_UNSUPPORTED=0
  CAMERA_RDI_SEEN_MISSING=0

  export CAMERA_RDI_SEEN_CAPTURE_FAIL
  export CAMERA_RDI_SEEN_UNSUPPORTED
  export CAMERA_RDI_SEEN_MISSING
}

camera_rdi_note_ret() {
  ret="$1"

  case "$ret" in
    0)
      return 0
      ;;
    1)
      CAMERA_RDI_SEEN_CAPTURE_FAIL=1
      ;;
    2)
      CAMERA_RDI_SEEN_UNSUPPORTED=1
      ;;
    3)
      CAMERA_RDI_SEEN_MISSING=1
      ;;
  esac

  export CAMERA_RDI_SEEN_CAPTURE_FAIL
  export CAMERA_RDI_SEEN_UNSUPPORTED
  export CAMERA_RDI_SEEN_MISSING

  return 0
}

camera_rdi_final_ret() {
  last_ret="$1"

  if [ "$last_ret" = "0" ]; then
    printf '0\n'
    return 0
  fi

  if [ "${CAMERA_RDI_SEEN_CAPTURE_FAIL:-0}" = "1" ]; then
    printf '1\n'
    return 0
  fi

  if [ "${CAMERA_RDI_SEEN_UNSUPPORTED:-0}" = "1" ]; then
    printf '2\n'
    return 0
  fi

  if [ "${CAMERA_RDI_SEEN_MISSING:-0}" = "1" ]; then
    printf '3\n'
    return 0
  fi

  printf '%s\n' "${last_ret:-1}"
}

camera_rdi_capture_attempt() {
  frames="$1"
  fmt="$2"

  execute_capture_block "$frames" "$fmt"
  ret=$?

  camera_rdi_exit_if_interrupted "$ret"
  camera_rdi_note_ret "$ret"

  return "$ret"
}

camera_rdi_replace_pad_size() {
  input="$1"
  old_size="$2"
  new_size="$3"

  if [ -z "$input" ]; then
    printf '\n'
    return 0
  fi

  if [ -z "$old_size" ] || [ -z "$new_size" ]; then
    printf '%s\n' "$input"
    return 0
  fi

  # Replace only media format sizes after "/", not entity names.
  # This avoids corrupting sensor names such as "ov08x40".
  printf '%s\n' "$input" | sed "s#/${old_size} #/${new_size} #g; s#/${old_size}]#/${new_size}]#g"
}

camera_rdi_try_set_stream_control() {
  subdev="$1"
  value="$2"

  [ -n "$subdev" ] || return 0
  [ "$subdev" != "None" ] || return 0
  [ -e "$subdev" ] || return 0

  timeout_secs="${YAVTA_CTRL_TIMEOUT_SECS:-10}"

  camera_rdi_log_cmd yavta --no-query -w "0x009f0903 $value" "$subdev"
  camera_rdi_timeout_cmd "$timeout_secs" \
    yavta --no-query -w "0x009f0903 $value" "$subdev"
  rc=$?

  case "$rc" in
    0)
      return 0
      ;;
    124|137|143)
      log_warn "yavta stream-control timed out on $subdev after ${timeout_secs}s"
      return 1
      ;;
    *)
      log_warn "yavta stream-control failed on $subdev rc=$rc"
      return 1
      ;;
  esac
}

camera_rdi_cleanup_stream_control() {
  subdev="$1"

  [ -n "$subdev" ] || return 0
  [ "$subdev" != "None" ] || return 0
  [ -e "$subdev" ] || return 0

  camera_rdi_try_set_stream_control "$subdev" 0 >/dev/null 2>&1 || true
  return 0
}

camera_rdi_find_parser() {
  parser=""
 
  if [ -n "${TOOLS:-}" ] && [ -f "$TOOLS/camera/parse_media_topology.py" ]; then
    parser="$TOOLS/camera/parse_media_topology.py"
  elif [ -n "${ROOT_DIR:-}" ] && [ -f "$ROOT_DIR/utils/camera/parse_media_topology.py" ]; then
    parser="$ROOT_DIR/utils/camera/parse_media_topology.py"
  elif [ -n "${REPO_ROOT:-}" ] && [ -f "$REPO_ROOT/utils/camera/parse_media_topology.py" ]; then
    parser="$REPO_ROOT/utils/camera/parse_media_topology.py"
  fi
 
  printf '%s\n' "$parser"
}
 
run_camera_pipeline_parser() {
  topo_file="${1:-}"
  parser="$(camera_rdi_find_parser)"
 
  if [ -z "$parser" ]; then
    log_warn "Camera topology parser not found: parse_media_topology.py"
    return 1
  fi
 
  if [ -z "$topo_file" ]; then
    log_warn "Topology file argument missing for parse_media_topology.py"
    return 1
  fi
 
  if [ ! -f "$topo_file" ]; then
    log_warn "Topology file not found: $topo_file"
    return 1
  fi
 
  python3 "$parser" "$topo_file"
}

execute_capture_block() {
  frames="$1"
  fmt="$2"

  case "$frames" in
    ''|*[!0-9]*)
      frames=10
      ;;
  esac

  [ -n "$fmt" ] || fmt="${YAVTA_FMT:-}"

  if [ -z "${YAVTA_DEV:-}" ] || [ "$YAVTA_DEV" = "None" ]; then
    log_skip "Missing yavta video device"
    return 3
  fi

  if [ ! -e "$YAVTA_DEV" ]; then
    log_skip "YAVTA device not found: $YAVTA_DEV"
    return 3
  fi

  if [ -z "$fmt" ] || [ "$fmt" = "None" ]; then
    log_skip "Missing YAVTA pixel format for $YAVTA_DEV"
    return 2
  fi

  capture_timeout="${CAPTURE_TIMEOUT_SECS:-45}"
  case "$capture_timeout" in
    ''|*[!0-9]*)
      capture_timeout=45
      ;;
  esac

  if [ "$capture_timeout" -lt 1 ] 2>/dev/null; then
    capture_timeout=45
  fi

  capture_dir="${CAMERA_RDI_CAPTURE_DIR:-./frames_${COUNT:-0}_$(basename "$YAVTA_DEV")_${fmt}}"
  mkdir -p "$capture_dir" 2>/dev/null || true
  capture_pattern="$capture_dir/frame-#.bin"

  # Avoid stale files from previous attempt/retry.
  rm -f "$capture_dir"/frame-*.bin 2>/dev/null || true

  # Best-effort cleanup before capture.
  camera_rdi_cleanup_stream_control "${YAVTA_SENSOR_SUBDEV:-}"

  if [ -n "${YAVTA_W:-}" ] && [ -n "${YAVTA_H:-}" ]; then
    camera_rdi_log_cmd yavta -B capture-mplane -c -I -n "$frames" -f "$fmt" \
      -s "${YAVTA_W}x${YAVTA_H}" -F "$YAVTA_DEV" --capture="$frames" --file="$capture_pattern"

    camera_rdi_timeout_cmd "$capture_timeout" \
      yavta -B capture-mplane -c -I -n "$frames" -f "$fmt" \
      -s "${YAVTA_W}x${YAVTA_H}" -F "$YAVTA_DEV" --capture="$frames" --file="$capture_pattern"
    rc=$?
  else
    camera_rdi_log_cmd yavta -B capture-mplane -c -I -n "$frames" -f "$fmt" \
      -F "$YAVTA_DEV" --capture="$frames" --file="$capture_pattern"

    camera_rdi_timeout_cmd "$capture_timeout" \
      yavta -B capture-mplane -c -I -n "$frames" -f "$fmt" \
      -F "$YAVTA_DEV" --capture="$frames" --file="$capture_pattern"
    rc=$?
  fi

  # Always try to leave the sensor/subdev in a sane state.
  camera_rdi_cleanup_stream_control "${YAVTA_SENSOR_SUBDEV:-}"

  case "$rc" in
    0)
      captured_count="$(
        find "$capture_dir" -type f -name 'frame-*.bin' -size +0c 2>/dev/null \
          | wc -l \
          | awk '{print $1}'
      )"

      log_info "Captured non-empty frame files in $capture_dir: ${captured_count:-0}"

      if [ "${captured_count:-0}" -gt 0 ]; then
        return 0
      fi

      log_warn "yavta returned success but no non-empty frame files were found in $capture_dir"
      return 1
      ;;

    130)
      log_warn "yavta capture interrupted by user on $YAVTA_DEV"
      return 130
      ;;

    124|137|143)
      log_fail "yavta capture timed out after ${capture_timeout}s on $YAVTA_DEV fmt=$fmt size=${YAVTA_W:-auto}x${YAVTA_H:-auto}"
      return 1
      ;;

    *)
      log_warn "yavta capture failed rc=$rc on $YAVTA_DEV fmt=$fmt size=${YAVTA_W:-auto}x${YAVTA_H:-auto}"

      # Only mark unsupported if v4l2-ctl successfully lists formats and fmt is absent.
      # If v4l2-ctl cannot list due to busy/bad state, keep it as capture failure.
      formats_out="$(v4l2-ctl -d "$YAVTA_DEV" --list-formats 2>/dev/null || true)"
      if [ -n "$formats_out" ]; then
        if printf '%s\n' "$formats_out" | grep -q "'$fmt'"; then
          return 1
        fi

        return 2
      fi

      return 1
      ;;
  esac
}
