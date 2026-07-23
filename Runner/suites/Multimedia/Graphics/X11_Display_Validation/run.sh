#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Validate the active X11 display, output mode, and root window.

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TESTNAME="X11_Display_Validation"
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

REQUIRE_XFCE="${REQUIRE_XFCE:-0}"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --require-xfce           Require a real XFCE session
  -h, --help               Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
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

case "$REQUIRE_XFCE" in
    0|1)
        ;;
    *)
        log_skip "$TESTNAME SKIP - REQUIRE_XFCE must be 0 or 1"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
        ;;
esac

rm -f "$RES_FILE"
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

log_info "-------------------------------------------------------------------"
log_info "---------------- Starting $TESTNAME testcase ----------------"

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
    if ! pkg_ensure_required_package_set_present graphics-x11-display; then
        log_skip "$TESTNAME SKIP - failed to ensure the X11 display package set"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

hash -r 2>/dev/null || true

deps="xdpyinfo xrandr xwininfo xprop awk sed grep tr"
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

if command -v display_debug_snapshot >/dev/null 2>&1; then
    display_debug_snapshot "$TESTNAME"
fi

connected_summary="$(display_connected_summary 2>/dev/null || true)"

if [ -z "$connected_summary" ] || [ "$connected_summary" = "none" ]; then
    log_skip "$TESTNAME SKIP - no connected DRM display was discovered"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Connected DRM displays: $connected_summary"

if ! display_x11_get_active_output; then
    log_fail "$TESTNAME FAIL - could not resolve an active XRandR output"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if ! display_x11_get_root_geometry; then
    log_fail "$TESTNAME FAIL - could not read the X11 root-window geometry"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

xrandr \
    --current \
    >"$OUTDIR/xrandr-current.log" 2>&1 || true

xwininfo \
    -root \
    >"$OUTDIR/xwininfo-root.log" 2>&1 || true

xprop \
    -root \
    >"$OUTDIR/xprop-root.log" 2>&1 || true

case "$DISPLAY_X11_REFRESH_HZ" in
    ''|*[!0-9.]*)
        log_fail "$TESTNAME FAIL - active XRandR refresh is invalid: ${DISPLAY_X11_REFRESH_HZ:-<empty>}"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
        ;;
esac

case "$DISPLAY_X11_ROOT_WIDTH:$DISPLAY_X11_ROOT_HEIGHT" in
    *[!0-9:]*|:*|*:)
        log_fail "$TESTNAME FAIL - root-window dimensions are invalid"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 0
        ;;
esac

if [ "$DISPLAY_X11_ROOT_MAP_STATE" != "IsViewable" ]; then
    log_fail "$TESTNAME FAIL - X11 root window is not viewable"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME PASS - session=${DISPLAY_X11_SESSION_KIND}; output=${DISPLAY_X11_OUTPUT}; mode=${DISPLAY_X11_MODE}; refresh=${DISPLAY_X11_REFRESH_HZ}Hz; root=${DISPLAY_X11_ROOT_WIDTH}x${DISPLAY_X11_ROOT_HEIGHT}"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
