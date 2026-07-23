#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Validate X11 video presentation using available GStreamer display sinks.

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TESTNAME="X11_GStreamer_Display"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

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
    echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
    exit 0
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_display.sh"

if [ -r "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_pkg_provider.sh"
fi

if [ -r "$TOOLS/lib_module_reload.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$TOOLS/lib_module_reload.sh"
fi

LC_ALL=C
export LC_ALL

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"

if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_skip "$TESTNAME SKIP - test path not found"
    echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
    exit 0
fi

if ! cd "$test_path"; then
    log_skip "$TESTNAME SKIP - cannot cd into $test_path"
    echo "$TESTNAME SKIP" >"$RES_FILE" 2>/dev/null || true
    exit 0
fi

RES_FILE="./${TESTNAME}.res"
LOG_DIR="./logs"
OUTDIR="$LOG_DIR/$TESTNAME"

# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_gstreamer.sh"

DURATION_SECONDS="${DURATION_SECONDS:-10}"
GST_SINK_MODE="${GST_SINK_MODE:-auto}"
REQUIRE_XFCE="${REQUIRE_XFCE:-0}"
X11_FULLSCREEN="${X11_FULLSCREEN:-1}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SELECTED_COUNT=0
FULLSCREEN_WATCH_AVAILABLE=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --duration <seconds>     Runtime for each selected pipeline
  --sink <mode>            auto, all, or comma-separated sink elements
  --fullscreen             Run sink windows fullscreen; default
  --windowed               Keep each sink window at its native size
  --require-xfce           Require a real XFCE session
  -h, --help              Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --duration)
            if [ "$#" -lt 2 ]; then
                log_skip "$TESTNAME SKIP - missing value for --duration"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi

            DURATION_SECONDS="$2"
            shift 2
            ;;
        --duration=*)
            DURATION_SECONDS=${1#*=}
            shift
            ;;
        --sink|--gst-sink)
            if [ "$#" -lt 2 ]; then
                log_skip "$TESTNAME SKIP - missing value for --sink"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi

            GST_SINK_MODE="$2"
            shift 2
            ;;
        --sink=*|--gst-sink=*)
            GST_SINK_MODE=${1#*=}
            shift
            ;;
        --fullscreen)
            X11_FULLSCREEN=1
            shift
            ;;
        --windowed)
            X11_FULLSCREEN=0
            shift
            ;;
        --require-xfce)
            REQUIRE_XFCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_skip "$TESTNAME SKIP - unknown option: $1"
            usage
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
    esac
done

case "$DURATION_SECONDS" in
    ''|*[!0-9]*|0)
        log_skip "$TESTNAME SKIP - duration must be a positive integer"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
        ;;
esac

case "$REQUIRE_XFCE" in
    0|1)
        ;;
    *)
        log_skip "$TESTNAME SKIP - REQUIRE_XFCE must be 0 or 1"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
        ;;
esac

case "$X11_FULLSCREEN" in
    0|1)
        ;;
    *)
        log_skip "$TESTNAME SKIP - X11_FULLSCREEN must be 0 or 1"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
        ;;
esac

rm -f "$RES_FILE"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

log_info "-------------------------------------------------------------------"
log_info "---------------- Starting $TESTNAME testcase ----------------"
log_info "DURATION_SECONDS=$DURATION_SECONDS GST_SINK_MODE=$GST_SINK_MODE"
log_info "X11_FULLSCREEN=$X11_FULLSCREEN"

GPU_BOOT_MODE="unknown"

if command -v mrv_qcom_gpu_boot_mode >/dev/null 2>&1; then
    GPU_BOOT_MODE="$(mrv_qcom_gpu_boot_mode 2>/dev/null || true)"
    [ -n "$GPU_BOOT_MODE" ] || GPU_BOOT_MODE="unknown"
fi

log_info "Detected Qualcomm GPU boot mode: $GPU_BOOT_MODE"

if [ "$GPU_BOOT_MODE" = "kgsl" ]; then
    log_skip "$TESTNAME SKIP - KGSL/proprietary Adreno boot mode requires the Weston/Wayland validation path"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if command -v pkg_ensure_required_package_set_present >/dev/null 2>&1; then
    if ! pkg_ensure_required_package_set_present graphics-x11-display ||
       ! pkg_ensure_required_package_set_present graphics-x11-gstreamer; then
        log_skip "$TESTNAME SKIP - failed to ensure the GStreamer X11 package sets"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi

fi

hash -r 2>/dev/null || true

deps="xdpyinfo xrandr gst-launch-1.0 gst-inspect-1.0 awk sed grep tr date"

if [ "$X11_FULLSCREEN" -eq 1 ]; then
    if command -v display_x11_prepare_fullscreen_support >/dev/null 2>&1 &&
       display_x11_prepare_fullscreen_support &&
       command -v display_x11_fullscreen_watch_start >/dev/null 2>&1 &&
       command -v display_x11_fullscreen_watch_finish >/dev/null 2>&1; then
        FULLSCREEN_WATCH_AVAILABLE=1
    else
        log_warn "Shared X11 fullscreen watcher is unavailable; GStreamer sink windows may remain windowed"
    fi
fi

check_dependencies "$deps"

if ! command -v display_x11_resolve_env >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL - display_x11_resolve_env helper is unavailable"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if ! display_x11_resolve_env \
    "${DISPLAY:-}" \
    "${XAUTHORITY:-}"; then
    log_skip "$TESTNAME SKIP - no usable X11 display and Xauthority pair could be discovered"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Resolved X11 runtime:"
log_info " DISPLAY=$DISPLAY"
log_info " XAUTHORITY=${XAUTHORITY:-<unset>}"
log_info " server_pid=${DISPLAY_X11_SERVER_PID:-unknown}"
log_info " session=${DISPLAY_X11_SESSION_KIND:-unknown}"

if [ "$REQUIRE_XFCE" -eq 1 ] &&
   [ "${DISPLAY_X11_SESSION_KIND:-unknown}" != "xfce" ]; then
    log_skip "$TESTNAME SKIP - real XFCE session required; detected ${DISPLAY_X11_SESSION_KIND:-unknown}"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if command -v ensure_xdg_runtime_dir >/dev/null 2>&1; then
    ensure_xdg_runtime_dir
fi

if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
    log_fail "$TESTNAME FAIL - could not prepare XDG_RUNTIME_DIR"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

case "$GST_SINK_MODE" in
    auto)
        requested_sinks="ximagesink glimagesink"

        if display_x11_xvideo_available; then
            requested_sinks="$requested_sinks xvimagesink"
        fi
        ;;
    all)
        requested_sinks="ximagesink glimagesink xvimagesink"
        ;;
    *)
        requested_sinks="$(printf '%s\n' "$GST_SINK_MODE" | tr ',' ' ')"
        ;;
esac

for sink in $requested_sinks; do
    [ -n "$sink" ] || continue
    SELECTED_COUNT=$((SELECTED_COUNT + 1))

    if ! has_element "$sink"; then
        log_skip "$sink SKIP - GStreamer element is unavailable"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if [ "$sink" = "xvimagesink" ] &&
       ! display_x11_xvideo_available; then
        log_skip "$sink SKIP - active X server exposes no XVideo adaptor"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    pipeline="videotestsrc is-live=true ! videoconvert ! ${sink} sync=true"
    sink_log="$OUTDIR/${sink}.log"

    old_gst_gl_window="${GST_GL_WINDOW:-}"
    old_gst_gl_platform="${GST_GL_PLATFORM:-}"
    old_gst_gl_api="${GST_GL_API:-}"
    had_gst_gl_window=0
    had_gst_gl_platform=0
    had_gst_gl_api=0

    [ "${GST_GL_WINDOW+x}" = "x" ] && had_gst_gl_window=1
    [ "${GST_GL_PLATFORM+x}" = "x" ] && had_gst_gl_platform=1
    [ "${GST_GL_API+x}" = "x" ] && had_gst_gl_api=1

    if [ "$sink" = "glimagesink" ]; then
        GST_GL_WINDOW="${GST_GL_WINDOW:-x11}"
        GST_GL_PLATFORM="${GST_GL_PLATFORM:-egl}"
        GST_GL_API="${GST_GL_API:-gles2}"
        export GST_GL_WINDOW GST_GL_PLATFORM GST_GL_API

        log_info "glimagesink environment: GST_GL_WINDOW=$GST_GL_WINDOW GST_GL_PLATFORM=$GST_GL_PLATFORM GST_GL_API=$GST_GL_API"
    fi

    if [ "$FULLSCREEN_WATCH_AVAILABLE" -eq 1 ]; then
        display_x11_fullscreen_watch_start \
            "$DURATION_SECONDS" \
            "gst-launch-1.0" \
            "$OUTDIR/${sink}-fullscreen.status" ||
            true
    fi

    sink_start="$(date +%s 2>/dev/null || echo 0)"

    gstreamer_run_gstlaunch_timeout \
        "$DURATION_SECONDS" \
        "$pipeline" \
        >"$sink_log" 2>&1

    sink_rc=$?
    sink_end="$(date +%s 2>/dev/null || echo 0)"
    sink_elapsed=$((sink_end - sink_start))

    if [ "$FULLSCREEN_WATCH_AVAILABLE" -eq 1 ]; then
        display_x11_fullscreen_watch_finish ||
            true
    fi

    if [ "$had_gst_gl_window" -eq 1 ]; then
        GST_GL_WINDOW="$old_gst_gl_window"
        export GST_GL_WINDOW
    else
        unset GST_GL_WINDOW
    fi

    if [ "$had_gst_gl_platform" -eq 1 ]; then
        GST_GL_PLATFORM="$old_gst_gl_platform"
        export GST_GL_PLATFORM
    else
        unset GST_GL_PLATFORM
    fi

    if [ "$had_gst_gl_api" -eq 1 ]; then
        GST_GL_API="$old_gst_gl_api"
        export GST_GL_API
    else
        unset GST_GL_API
    fi

    cat "$sink_log"

    if grep -q 'ERROR:' "$sink_log" 2>/dev/null; then
        log_fail "$sink FAIL - GStreamer reported an error, rc=$sink_rc"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if ! grep -Eq \
        'Pipeline is PLAYING|Setting pipeline to PLAYING' \
        "$sink_log" 2>/dev/null; then
        log_fail "$sink FAIL - pipeline never reached PLAYING, rc=$sink_rc"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    case "$sink_rc" in
        0|124|130|137|143)
            if [ "$sink_elapsed" -lt $((DURATION_SECONDS - 1)) ] 2>/dev/null; then
                log_fail "$sink FAIL - pipeline exited too early: elapsed=${sink_elapsed}s requested=${DURATION_SECONDS}s rc=$sink_rc"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            else
                log_pass "$sink PASS - reached PLAYING for ${sink_elapsed}s rc=$sink_rc"
                PASS_COUNT=$((PASS_COUNT + 1))
            fi
            ;;
        *)
            log_fail "$sink FAIL - unexpected gst-launch return code: $sink_rc"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac
done

if [ "$SELECTED_COUNT" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no GStreamer sink was selected"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    log_fail "$TESTNAME FAIL - $FAIL_COUNT sink(s) failed; $PASS_COUNT passed; $SKIP_COUNT skipped"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ "$PASS_COUNT" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no GStreamer sink completed; $SKIP_COUNT skipped"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME PASS - $PASS_COUNT sink(s) passed; $SKIP_COUNT skipped"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
