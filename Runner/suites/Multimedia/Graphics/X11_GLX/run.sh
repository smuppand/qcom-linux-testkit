#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Validate GLX hardware rendering and refresh-synchronised frame progress.

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TESTNAME="X11_GLX"
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
REQUIRE_XFCE="${REQUIRE_XFCE:-0}"
X11_FULLSCREEN="${X11_FULLSCREEN:-1}"
FAILURES=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --duration <seconds>     glxgears runtime; minimum 6 seconds
  --fullscreen             Run glxgears fullscreen; default
  --windowed               Keep the native glxgears window size
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

if [ "$DURATION_SECONDS" -lt 6 ]; then
    log_skip "$TESTNAME SKIP - duration must be at least 6 seconds for FPS collection"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

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

GLXINFO_LOG="$OUTDIR/glxinfo-B.log"
GLXGEARS_LOG="$OUTDIR/glxgears.log"

log_info "-------------------------------------------------------------------"
log_info "---------------- Starting $TESTNAME testcase ----------------"
log_info "DURATION_SECONDS=$DURATION_SECONDS"
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

deps="xdpyinfo xrandr glxinfo glxgears awk sed grep tr date"
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

GLX_REFRESH_HZ=""

if command -v display_get_primary_refresh_hz >/dev/null 2>&1; then
    GLX_REFRESH_HZ="$(display_get_primary_refresh_hz x11 2>/dev/null || true)"
fi

case "$GLX_REFRESH_HZ" in
    ''|*[!0-9.]*)
        GLX_REFRESH_HZ=""
        log_warn "Could not capture the active XRandR refresh before glxgears"
        ;;
    *)
        log_info "Captured active XRandR refresh before glxgears: ${GLX_REFRESH_HZ}Hz"
        ;;
esac

if ! command -v display_x11_print_glx_pipeline >/dev/null 2>&1; then
    log_fail "$TESTNAME FAIL - shared display_x11_print_glx_pipeline helper is unavailable in lib_display.sh"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if ! display_x11_print_glx_pipeline >"$GLXINFO_LOG" 2>&1; then
    cat "$GLXINFO_LOG"
    log_fail "$TESTNAME FAIL - glxinfo could not initialize the selected X11 display"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

cat "$GLXINFO_LOG"

case "$(printf '%s\n' "${DISPLAY_GLX_DIRECT:-}" | tr '[:upper:]' '[:lower:]')" in
    yes)
        ;;
    *)
        log_fail "Direct rendering is not enabled"
        FAILURES=$((FAILURES + 1))
        ;;
esac

case "$(printf '%s\n' "${DISPLAY_GLX_ACCELERATED:-}" | tr '[:upper:]' '[:lower:]')" in
    no)
        log_fail "GLX reports an unaccelerated renderer"
        FAILURES=$((FAILURES + 1))
        ;;
esac

case "${DISPLAY_GLX_PIPE_KIND:-}" in
    CPU*)
        log_fail "Software GLX renderer detected: ${DISPLAY_GLX_RENDERER:-unknown}"
        FAILURES=$((FAILURES + 1))
        ;;
esac

if [ "${DISPLAY_GLX_RENDERER:-unknown}" = "unknown" ]; then
    log_fail "GLX renderer could not be identified"
    FAILURES=$((FAILURES + 1))
fi

set -- \
    glxgears

if [ "$X11_FULLSCREEN" -eq 1 ]; then
    set -- \
        "$@" \
        -fullscreen
fi


glxgears_start="$(date +%s 2>/dev/null || echo 0)"

run_with_timeout \
    "${DURATION_SECONDS}s" \
    "$@" \
    >"$GLXGEARS_LOG" 2>&1

glxgears_rc=$?
glxgears_end="$(date +%s 2>/dev/null || echo 0)"
glxgears_elapsed=$((glxgears_end - glxgears_start))


cat "$GLXGEARS_LOG"

case "$glxgears_rc" in
    0|124|130|137|143)
        ;;
    *)
        log_fail "glxgears failed with rc=$glxgears_rc"
        FAILURES=$((FAILURES + 1))
        ;;
esac

if [ "$glxgears_elapsed" -lt $((DURATION_SECONDS - 1)) ] 2>/dev/null; then
    log_fail "glxgears exited too early: elapsed=${glxgears_elapsed}s requested=${DURATION_SECONDS}s rc=$glxgears_rc"
    FAILURES=$((FAILURES + 1))
else
    log_info "glxgears bounded runtime: elapsed=${glxgears_elapsed}s rc=$glxgears_rc"
fi

DISPLAY_FPS_BACKEND=x11

if [ -n "${EXPECT_FPS:-}" ]; then
    FPS_EXPECT_MODE="${FPS_EXPECT_MODE:-fixed}"
elif [ -n "$GLX_REFRESH_HZ" ]; then
    EXPECT_FPS="$GLX_REFRESH_HZ"
    FPS_EXPECT_MODE="fixed"
    log_info "Using captured XRandR refresh for FPS policy: ${EXPECT_FPS}Hz"
else
    FPS_EXPECT_MODE="${FPS_EXPECT_MODE:-detected}"
fi

export DISPLAY_FPS_BACKEND FPS_EXPECT_MODE EXPECT_FPS

if ! display_resolve_fps_policy; then
    log_fail "Could not derive FPS policy from the active XRandR refresh"
    FAILURES=$((FAILURES + 1))
elif ! display_parse_fps_log "$GLXGEARS_LOG"; then
    log_fail "No glxgears FPS sample was parsed"
    FAILURES=$((FAILURES + 1))
elif ! display_fps_gate_avg \
    "$DISPLAY_FPS_AVG" \
    "$DISPLAY_FPS_COUNT"; then
    FAILURES=$((FAILURES + 1))
else
    log_pass "glxgears FPS: avg=$DISPLAY_FPS_AVG min=$DISPLAY_FPS_MIN max=$DISPLAY_FPS_MAX samples=$DISPLAY_FPS_COUNT"
fi

if [ "$FAILURES" -gt 0 ]; then
    log_fail "$TESTNAME FAIL - $FAILURES GLX validation check(s) failed"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME PASS - \
direct=${DISPLAY_GLX_DIRECT:-unknown}; \
accelerated=${DISPLAY_GLX_ACCELERATED:-unknown}; \
vendor=${DISPLAY_GLX_VENDOR:-unknown}; \
renderer=${DISPLAY_GLX_RENDERER:-unknown}; \
refresh=${GLX_REFRESH_HZ:-${DISPLAY_X11_REFRESH_HZ:-unknown}}Hz; \
avg_fps=${DISPLAY_FPS_AVG:-unknown}"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
