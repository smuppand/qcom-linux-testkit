#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Validate the X11 EGL pipeline and available GLES client applications.

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TESTNAME="X11_EGL_GLES"
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

DURATION_SECONDS="${DURATION_SECONDS:-12}"
GLES_APPS="${GLES_APPS:-auto}"
REQUIRE_XFCE="${REQUIRE_XFCE:-0}"
X11_FULLSCREEN="${X11_FULLSCREEN:-1}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FULLSCREEN_WATCH_AVAILABLE=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --duration <seconds>     Runtime for each EGL/GLES client
  --apps <list>            auto or comma-separated client commands
  --fullscreen             Run visual clients fullscreen; default
  --windowed               Keep each client's native window size
  --require-xfce           Require a real XFCE session
  -h, --help               Show this help
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
        --apps|--gles-apps)
            if [ "$#" -lt 2 ]; then
                log_skip "$TESTNAME SKIP - missing value for --apps"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi

            GLES_APPS="$2"
            shift 2
            ;;
        --apps=*|--gles-apps=*)
            GLES_APPS=${1#*=}
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

if ! mkdir -p "$OUTDIR"; then
    log_skip "$TESTNAME SKIP - could not create output directory: $OUTDIR"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

EGLINFO_LOG="$OUTDIR/eglinfo-x11.log"

log_info "-------------------------------------------------------------------"
log_info "---------------- Starting $TESTNAME testcase ----------------"
log_info "DURATION_SECONDS=$DURATION_SECONDS"
log_info "GLES_APPS=$GLES_APPS"
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
       ! pkg_ensure_required_package_set_present graphics-x11-mesa; then
        log_skip "$TESTNAME SKIP - failed to ensure the X11 Mesa package sets"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi

fi

hash -r 2>/dev/null || true

deps="xdpyinfo xrandr eglinfo awk sed grep tr date"

if [ "$X11_FULLSCREEN" -eq 1 ]; then
    if command -v display_x11_prepare_fullscreen_support >/dev/null 2>&1 &&
       display_x11_prepare_fullscreen_support &&
       command -v display_x11_fullscreen_watch_start >/dev/null 2>&1 &&
       command -v display_x11_fullscreen_watch_finish >/dev/null 2>&1; then
        FULLSCREEN_WATCH_AVAILABLE=1
    else
        log_warn "Shared X11 fullscreen watcher is unavailable; EGL/GLES clients may remain windowed"
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

EGLINFO_CACHE_OUTPUT=1
export EGLINFO_CACHE_OUTPUT

if ! display_print_eglinfo_pipeline \
    x11; then
    log_fail "$TESTNAME FAIL - selected X11 EGL platform did not initialize"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ -n "${EGLI_LAST_OUT:-}" ]; then
    if ! printf '%s\n' \
        "$EGLI_LAST_OUT" \
        >"$EGLINFO_LOG"; then
        log_warn "Failed to save selected X11 eglinfo output: $EGLINFO_LOG"
    fi
else
    log_warn "Selected X11 eglinfo output was not cached"
fi

log_info "Selected X11 EGL pipeline:"
log_info " platform=${EGLI_LAST_PLATFORM:-unknown}"
log_info " EGL vendor=${EGLI_LAST_EGL_VENDOR:-unknown}"
log_info " EGL version=${EGLI_LAST_EGL_VERSION:-unknown}"
log_info " EGL API version=${EGLI_LAST_EGL_API_VERSION:-unknown}"
log_info " EGL driver=${EGLI_LAST_DRIVER:-unknown}"
log_info " GL vendor=${EGLI_LAST_GL_VENDOR:-unknown}"
log_info " GL renderer=${EGLI_LAST_GL_RENDERER:-unknown}"
log_info " pipeline type=${EGLI_LAST_PIPE_KIND:-unknown}"

if [ "${EGLI_LAST_PLATFORM:-}" != "x11" ]; then
    log_fail "$TESTNAME FAIL - unexpected EGL platform: ${EGLI_LAST_PLATFORM:-unknown}"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

case "${EGLI_LAST_PIPE_KIND:-}" in
    CPU*)
        log_fail "$TESTNAME FAIL - software X11 EGL renderer detected: ${EGLI_LAST_GL_RENDERER:-unknown}"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
        ;;
    GPU*)
        ;;
    *)
        log_fail "$TESTNAME FAIL - X11 EGL pipeline type could not be classified: ${EGLI_LAST_PIPE_KIND:-unknown}"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
        ;;
esac

if [ -z "${EGLI_LAST_EGL_VENDOR:-}" ] ||
   [ "$EGLI_LAST_EGL_VENDOR" = "unknown" ] ||
   [ -z "${EGLI_LAST_EGL_VERSION:-}" ] ||
   [ "$EGLI_LAST_EGL_VERSION" = "unknown" ] ||
   [ -z "${EGLI_LAST_EGL_API_VERSION:-}" ] ||
   [ "$EGLI_LAST_EGL_API_VERSION" = "unknown" ] ||
   [ -z "${EGLI_LAST_DRIVER:-}" ] ||
   [ "$EGLI_LAST_DRIVER" = "unknown" ] ||
   [ -z "${EGLI_LAST_GL_VENDOR:-}" ] ||
   [ "$EGLI_LAST_GL_VENDOR" = "unknown" ] ||
   [ -z "${EGLI_LAST_GL_RENDERER:-}" ] ||
   [ "$EGLI_LAST_GL_RENDERER" = "unknown" ]; then
    log_fail "$TESTNAME FAIL - X11 EGL vendor, version, API version, driver, or renderer could not be identified"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if command -v es2_info >/dev/null 2>&1; then
    if es2_info >"$OUTDIR/es2-info.log" 2>&1; then
        cat "$OUTDIR/es2-info.log"
        log_pass "es2_info initialized on the selected X11 display"
    else
        cat "$OUTDIR/es2-info.log"
        log_fail "$TESTNAME FAIL - es2_info failed on the selected X11 display"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
    fi
else
    log_warn "es2_info is unavailable; continuing with the X11 EGL clients"
fi

requested_apps="$(printf '%s\n' "$GLES_APPS" | tr ',' ' ')"

if [ "$requested_apps" = "auto" ]; then
    requested_apps="es2gears_x11 eglgears_x11 egltri_x11"
fi

for app in $requested_apps; do
    [ -n "$app" ] || continue

    if ! command -v "$app" >/dev/null 2>&1; then
        log_skip "$app SKIP - client is unavailable"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    app_name="$(basename "$app")"
    app_log="$OUTDIR/${app_name}.log"

    if [ "$FULLSCREEN_WATCH_AVAILABLE" -eq 1 ]; then
        display_x11_fullscreen_watch_start \
            "$DURATION_SECONDS" \
            "$app_name" \
            "$OUTDIR/${app_name}-fullscreen.status" ||
            true
    fi

    app_start="$(date +%s 2>/dev/null || echo 0)"

    run_with_timeout \
        "${DURATION_SECONDS}s" \
        "$app" \
        >"$app_log" 2>&1

    app_rc=$?
    app_end="$(date +%s 2>/dev/null || echo 0)"
    app_elapsed=$((app_end - app_start))

    if [ "$FULLSCREEN_WATCH_AVAILABLE" -eq 1 ]; then
        display_x11_fullscreen_watch_finish ||
            true
    fi

    cat "$app_log"

    case "$app_rc" in
        0|124|130|137|143)
            minimum_elapsed=$((DURATION_SECONDS - 1))

            if [ "$app_elapsed" -lt "$minimum_elapsed" ]; then
                log_fail "$app FAIL - exited too early: elapsed=${app_elapsed}s requested=${DURATION_SECONDS}s rc=$app_rc"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            else
                log_pass "$app PASS - remained active for ${app_elapsed}s rc=$app_rc"
                PASS_COUNT=$((PASS_COUNT + 1))
            fi
            ;;
        *)
            log_fail "$app FAIL - unexpected return code: $app_rc"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
    esac
done

if [ "$FAIL_COUNT" -gt 0 ]; then
    log_fail "$TESTNAME FAIL - $FAIL_COUNT client(s) failed; $PASS_COUNT passed; $SKIP_COUNT skipped"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ "$PASS_COUNT" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no EGL/GLES client completed; $SKIP_COUNT skipped"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME PASS - \
egl=${EGLI_LAST_EGL_VERSION:-unknown}; \
driver=${EGLI_LAST_DRIVER:-unknown}; \
vendor=${EGLI_LAST_GL_VENDOR:-unknown}; \
renderer=${EGLI_LAST_GL_RENDERER:-unknown}; \
clients=$PASS_COUNT"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
