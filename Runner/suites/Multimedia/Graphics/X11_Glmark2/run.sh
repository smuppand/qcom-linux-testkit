#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Validate desktop OpenGL and OpenGL ES rendering with bounded glmark2 scenes.

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TESTNAME="X11_Glmark2"
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

DURATION_SECONDS="${DURATION_SECONDS:-5}"
GLMARK_TIMEOUT_SECONDS="${GLMARK_TIMEOUT_SECONDS:-auto}"
GLMARK_BENCHMARKS="${GLMARK_BENCHMARKS:-auto}"
GLMARK_BINARIES="${GLMARK_BINARIES:-auto}"
REQUIRE_XFCE="${REQUIRE_XFCE:-0}"
X11_FULLSCREEN="${X11_FULLSCREEN:-1}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --duration <seconds>     Default glmark2 scene duration
  --timeout <seconds>      Per-binary timeout, or auto
  --benchmarks <list>      Comma-separated benchmark specifications
  --binaries <list>       auto or comma-separated glmark2 commands
  --fullscreen             Run glmark2 fullscreen; default
  --windowed               Keep the native glmark2 window size
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
        --timeout|--glmark-timeout)
            if [ "$#" -lt 2 ]; then
                log_skip "$TESTNAME SKIP - missing value for --timeout"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi

            GLMARK_TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --timeout=*|--glmark-timeout=*)
            GLMARK_TIMEOUT_SECONDS=${1#*=}
            shift
            ;;
        --benchmarks|--glmark-benchmarks)
            if [ "$#" -lt 2 ]; then
                log_skip "$TESTNAME SKIP - missing value for --benchmarks"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi

            GLMARK_BENCHMARKS="$2"
            shift 2
            ;;
        --benchmarks=*|--glmark-benchmarks=*)
            GLMARK_BENCHMARKS=${1#*=}
            shift
            ;;
        --binaries|--glmark-binaries)
            if [ "$#" -lt 2 ]; then
                log_skip "$TESTNAME SKIP - missing value for --binaries"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi

            GLMARK_BINARIES="$2"
            shift 2
            ;;
        --binaries=*|--glmark-binaries=*)
            GLMARK_BINARIES=${1#*=}
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

if [ "$GLMARK_BENCHMARKS" = "auto" ]; then
    GLMARK_BENCHMARKS=":duration=${DURATION_SECONDS}.0,build:use-vbo=true"
fi

benchmarks="$(printf '%s\n' "$GLMARK_BENCHMARKS" | tr ',' ' ')"
benchmark_count=0

for benchmark in $benchmarks; do
    [ -n "$benchmark" ] || continue

    case "$benchmark" in
        :*)
            ;;
        *)
            benchmark_count=$((benchmark_count + 1))
            ;;
    esac
done

if [ "$benchmark_count" -eq 0 ]; then
    benchmark_count=1
fi

if [ "$GLMARK_TIMEOUT_SECONDS" = "auto" ]; then
    GLMARK_TIMEOUT_SECONDS=$((DURATION_SECONDS * benchmark_count + 30))
else
    case "$GLMARK_TIMEOUT_SECONDS" in
        ''|*[!0-9]*|0)
            log_skip "$TESTNAME SKIP - timeout must be auto or a positive integer"
            echo "$TESTNAME SKIP" >"$RES_FILE"
            exit 0
            ;;
    esac
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

log_info "-------------------------------------------------------------------"
log_info "---------------- Starting $TESTNAME testcase ----------------"
log_info "DURATION_SECONDS=$DURATION_SECONDS"
log_info "GLMARK_TIMEOUT_SECONDS=$GLMARK_TIMEOUT_SECONDS"
log_info "GLMARK_BENCHMARKS=$GLMARK_BENCHMARKS"
log_info "GLMARK_BINARIES=$GLMARK_BINARIES"
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
       ! pkg_ensure_required_package_set_present graphics-x11-glmark2; then
        log_skip "$TESTNAME SKIP - failed to ensure the glmark2 X11 package sets"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

hash -r 2>/dev/null || true

deps="xdpyinfo xrandr awk sed grep tr"
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

requested_bins="$(printf '%s\n' "$GLMARK_BINARIES" | tr ',' ' ')"

if [ "$requested_bins" = "auto" ]; then
    requested_bins="glmark2 glmark2-es2"
fi

for bin in $requested_bins; do
    [ -n "$bin" ] || continue

    if ! command -v "$bin" >/dev/null 2>&1; then
        if command -v pkg_ensure_command >/dev/null 2>&1; then
            pkg_ensure_command "$bin" >/dev/null 2>&1 || true
            hash -r 2>/dev/null || true
        fi
    fi

    if ! command -v "$bin" >/dev/null 2>&1; then
        log_skip "$bin SKIP - benchmark binary is unavailable"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    bin_name="$(basename "$bin")"
    log_file="$OUTDIR/${bin_name}.log"
    set -- \
        "$bin"

    if [ "$X11_FULLSCREEN" -eq 1 ]; then
        set -- \
            "$@" \
            --fullscreen
    fi

    for benchmark in $benchmarks; do
        [ -n "$benchmark" ] || continue

        set -- \
            "$@" \
            --benchmark \
            "$benchmark"
    done

    run_with_timeout \
        "${GLMARK_TIMEOUT_SECONDS}s" \
        "$@" \
        >"$log_file" 2>&1

    glmark_rc=$?

    cat "$log_file"

    if [ "$glmark_rc" -ne 0 ]; then
        log_fail "$bin FAIL - benchmark did not complete, rc=$glmark_rc"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    vendor="$(
        sed -n \
            's/^[[:space:]]*GL_VENDOR:[[:space:]]*//p' \
            "$log_file" |
            head -n 1
    )"
    renderer="$(
        sed -n \
            's/^[[:space:]]*GL_RENDERER:[[:space:]]*//p' \
            "$log_file" |
            head -n 1
    )"
    version="$(
        sed -n \
            's/^[[:space:]]*GL_VERSION:[[:space:]]*//p' \
            "$log_file" |
            head -n 1
    )"
    score="$(
        awk '
            /glmark2 Score:/ {
                sub(/^.*glmark2 Score:[[:space:]]*/, "")
                print $1
                exit
            }
        ' "$log_file"
    )"
    pipeline_kind="$(
        egli_classify_pipeline \
            "" \
            "$vendor" \
            "$renderer"
    )"

    case "$pipeline_kind" in
        CPU*)
            log_fail "$bin FAIL - software renderer detected: ${renderer:-unknown}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
            ;;
    esac

    case "$score" in
        ''|*[!0-9.]*)
            log_fail "$bin FAIL - numeric glmark2 score was not produced"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
            ;;
    esac

    log_pass "$bin PASS - score=$score; vendor=${vendor:-unknown}; renderer=${renderer:-unknown}; version=${version:-unknown}"
    PASS_COUNT=$((PASS_COUNT + 1))
done

if [ "$FAIL_COUNT" -gt 0 ]; then
    log_fail "$TESTNAME FAIL - $FAIL_COUNT benchmark(s) failed; $PASS_COUNT passed; $SKIP_COUNT skipped"
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 0
fi

if [ "$PASS_COUNT" -eq 0 ]; then
    log_skip "$TESTNAME SKIP - no benchmark completed; $SKIP_COUNT skipped"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_pass "$TESTNAME PASS - $PASS_COUNT benchmark binary/binaries passed; $SKIP_COUNT skipped"
echo "$TESTNAME PASS" >"$RES_FILE"
exit 0
