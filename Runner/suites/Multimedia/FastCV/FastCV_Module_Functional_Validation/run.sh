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
# shellcheck disable=SC1091
. "$TOOLS/lib_pkg_provider.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_fastcv.sh"
TESTNAME="FastCV_Module_Functional_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

FASTCV_TEST_BINARY="${FASTCV_TEST_BINARY:-}"
FASTCV_TEST_DATA_DIR="${FASTCV_TEST_DATA_DIR:-}"
FASTCV_TEST_TARGETS="${FASTCV_TEST_TARGETS:-6}"
FASTCV_TEST_MODULES="${FASTCV_TEST_MODULES:-COLORYUV,SCALE,ARITHM,BLUR,TRNS}"
FASTCV_TEST_LOOPS="${FASTCV_TEST_LOOPS:-10}"
FASTCV_TEST_LEVEL="${FASTCV_TEST_LEVEL:-10}"
FASTCV_TEST_TIMEOUT="${FASTCV_TEST_TIMEOUT:-300}"
FASTCV_TEST_FUNCTION="${FASTCV_TEST_FUNCTION:-}"
FASTCV_TEST_OPERATION_MODE="${FASTCV_TEST_OPERATION_MODE:-}"
FASTCV_TEST_OPERATION_TABLES_ONLY="${FASTCV_TEST_OPERATION_TABLES_ONLY:-0}"
FASTCV_TEST_SEED="${FASTCV_TEST_SEED:-}"
FASTCV_TEST_NO_BUFFER_POOL="${FASTCV_TEST_NO_BUFFER_POOL:-0}"
FASTCV_TEST_PREALLOC_BYTES="${FASTCV_TEST_PREALLOC_BYTES:-}"
FASTCV_TEST_OPENCV="${FASTCV_TEST_OPENCV:-0}"
FASTCV_TEST_UNIT_ONLY="${FASTCV_TEST_UNIT_ONLY:-0}"
FASTCV_TEST_PROFILE_ONLY="${FASTCV_TEST_PROFILE_ONLY:-0}"
FASTCV_TEST_EXHAUSTIVE="${FASTCV_TEST_EXHAUSTIVE:-0}"
FASTCV_TEST_RESOLUTION="${FASTCV_TEST_RESOLUTION:-}"
FASTCV_TEST_QDSP_HEAP="${FASTCV_TEST_QDSP_HEAP:-0}"
FASTCV_TEST_ELEMENT_ALIGNMENT="${FASTCV_TEST_ELEMENT_ALIGNMENT:-0}"
FASTCV_TEST_CACHE_FLUSH="${FASTCV_TEST_CACHE_FLUSH:-0}"
FASTCV_TEST_WITHOUT_OPERATION_MODE="${FASTCV_TEST_WITHOUT_OPERATION_MODE:-0}"
FASTCV_TEST_MAX_CASES=64
RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
BINARY_REPORT="$RESULT_DIR/fastcv_test_binary.log"
DATA_REPORT="$RESULT_DIR/fastcv_test_data_files.log"
CONTROL_TABLE=""
TARGET_LIST="$RESULT_DIR/fastcv_targets.list"
MODULE_LIST="$RESULT_DIR/fastcv_modules.list"
DSP_TARGET_SELECTED=0

# usage
# Print required fixture paths and configurable fastcv_test arguments.
# Inputs: none. Output: help text on stdout. Returns: 0. Side effects: none.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh --binary PATH --data-dir DIR [options]" \
        "  --binary PATH       Sideloaded fastcv_test executable" \
        "  --data-dir DIR      Matching sideloaded FastCV data directory" \
        "  --targets LIST      Comma-separated 0,2,4,6,8, default: 6" \
        "  --modules LIST      all or comma-separated modules" \
        "                      default: COLORYUV,SCALE,ARITHM,BLUR,TRNS" \
        "  --loops COUNT       Value passed with -l, default: 10" \
        "  --level COUNT       Value passed with -L for all modules, default: 10" \
        "  --timeout SECONDS   Bound each invocation, default: 300" \
        "  --function NAME     Limit to one function, requires one focused module" \
        "  --operation-mode N  Value passed with -M, accepted: 0 through 8" \
        "  --operation-tables-only 0|1  Pass -OPT" \
        "  --seed INTEGER      Value passed with -s, empty keeps binary default" \
        "  --no-buffer-pool 0|1       Pass -nbp" \
        "  --prealloc-bytes N         Pass -psb N" \
        "  --opencv 0|1               Pass -o" \
        "  --unit-only 0|1            Pass -U" \
        "  --profile-only 0|1         Pass -P" \
        "  --exhaustive 0|1           Pass -E" \
        "  --resolution N             Pass -S, accepted: 0 through 7" \
        "  --qdsp-heap 0|1            Pass -H" \
        "  --element-alignment 0|1    Pass -AL" \
        "  --cache-flush 0|1          Pass -C" \
        "  --without-operation-mode 0|1  Pass -TWOp" \
        "  -h, --help" \
        "The binary and data folder are external fixture assets and must be provided together."
}

# parse_args ARG...
# Parse CLI values into the suite configuration globals.
# Inputs: command-line arguments. Output: no stdout.
# Returns: 0 on success, 2 for invalid input, or exits after help.
# Side effects: updates all FASTCV_TEST_* configuration globals.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --binary)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_BINARY="$2"
                shift 2
                ;;
            --data-dir)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_DATA_DIR="$2"
                shift 2
                ;;
            --targets)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_TARGETS="$2"
                shift 2
                ;;
            --modules)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_MODULES="$2"
                shift 2
                ;;
            --loops)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_LOOPS="$2"
                shift 2
                ;;
            --level)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_LEVEL="$2"
                shift 2
                ;;
            --timeout)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_TIMEOUT="$2"
                shift 2
                ;;
            --function)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_FUNCTION="$2"
                shift 2
                ;;
            --operation-mode)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_OPERATION_MODE="$2"
                shift 2
                ;;
            --operation-tables-only)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_OPERATION_TABLES_ONLY="$2"
                shift 2
                ;;
            --seed)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_SEED="$2"
                shift 2
                ;;
            --no-buffer-pool)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_NO_BUFFER_POOL="$2"
                shift 2
                ;;
            --prealloc-bytes)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_PREALLOC_BYTES="$2"
                shift 2
                ;;
            --opencv)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_OPENCV="$2"
                shift 2
                ;;
            --unit-only)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_UNIT_ONLY="$2"
                shift 2
                ;;
            --profile-only)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_PROFILE_ONLY="$2"
                shift 2
                ;;
            --exhaustive)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_EXHAUSTIVE="$2"
                shift 2
                ;;
            --resolution)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_RESOLUTION="$2"
                shift 2
                ;;
            --qdsp-heap)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_QDSP_HEAP="$2"
                shift 2
                ;;
            --element-alignment)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_ELEMENT_ALIGNMENT="$2"
                shift 2
                ;;
            --cache-flush)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_CACHE_FLUSH="$2"
                shift 2
                ;;
            --without-operation-mode)
                [ "$#" -ge 2 ] || return 2
                FASTCV_TEST_WITHOUT_OPERATION_MODE="$2"
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

# validate_boolean_option NAME VALUE
# Validate one wrapper boolean encoded as 0 or 1.
# Inputs: user-facing option name and value. Output: error log on invalid input.
# Returns: 0 for 0 or 1, and 1 otherwise. Side effects: none beyond logging.
validate_boolean_option() {
    vbo_name="$1"
    vbo_value="$2"

    case "$vbo_value" in
        0|1)
            return 0
            ;;
        *)
            log_error "$vbo_name must be 0 or 1, observed=${vbo_value:-empty}"
            return 1
            ;;
    esac
}

# prepare_target_list TARGETS OUTPUT_FILE
# Validate target selectors and write one deduplicated target per line.
# Inputs: comma-separated selectors and retained output path.
# Output: no stdout. Returns: 0 for valid selectors or 1 otherwise.
# Side effects: replaces OUTPUT_FILE and updates DSP_TARGET_SELECTED.
prepare_target_list() {
    ptl_targets="$1"
    ptl_output="$2"
    ptl_raw="$ptl_output.raw"
    ptl_error=""
    DSP_TARGET_SELECTED=0

    rm -f "$ptl_output" "$ptl_raw"
    if ! printf '%s\n' "$ptl_targets" | tr ',' '\n' >"$ptl_raw"; then
        return 1
    fi

    while IFS= read -r ptl_target; do
        case "$ptl_target" in
            0|2|4|6|8)
                ;;
            *)
                ptl_error="Invalid FastCV target selector: ${ptl_target:-empty}"
                break
                ;;
        esac
        if grep -Fxq "$ptl_target" "$ptl_output" 2>/dev/null; then
            ptl_error="Duplicate FastCV target selector: $ptl_target"
            break
        fi
        printf '%s\n' "$ptl_target" >>"$ptl_output"
        case "$ptl_target" in
            0|8)
                DSP_TARGET_SELECTED=1
                ;;
        esac
    done <"$ptl_raw"
    rm -f "$ptl_raw"

    if [ -n "$ptl_error" ]; then
        log_error "$ptl_error"
        return 1
    fi

    [ -s "$ptl_output" ]
}

# prepare_module_list MODULES OUTPUT_FILE
# Validate a module selector or normalize all-module mode to the ALL token.
# Inputs: all or a comma-separated module list, and retained output path.
# Output: no stdout. Returns: 0 for valid selectors or 1 otherwise.
# Side effects: replaces OUTPUT_FILE and its temporary raw selector file.
prepare_module_list() {
    pml_modules="$1"
    pml_output="$2"
    pml_raw="$pml_output.raw"
    pml_normalized=$(printf '%s\n' "$pml_modules" | tr '[:lower:]' '[:upper:]')
    pml_error=""

    rm -f "$pml_output" "$pml_raw"
    if [ "$pml_normalized" = "ALL" ]; then
        printf 'ALL\n' >"$pml_output"
        return 0
    fi
    if ! printf '%s\n' "$pml_normalized" | tr ',' '\n' >"$pml_raw"; then
        return 1
    fi

    while IFS= read -r pml_module; do
        case "$pml_module" in
            ''|*[!A-Z0-9_+-]*)
                pml_error="Invalid FastCV module selector: ${pml_module:-empty}"
                break
                ;;
        esac
        if grep -Fxq "$pml_module" "$pml_output" 2>/dev/null; then
            pml_error="Duplicate FastCV module selector: $pml_module"
            break
        fi
        printf '%s\n' "$pml_module" >>"$pml_output"
    done <"$pml_raw"
    rm -f "$pml_raw"

    if [ -n "$pml_error" ]; then
        log_error "$pml_error"
        return 1
    fi

    [ -s "$pml_output" ]
}

# run_fastcv_test_case TARGET MODULE
# Execute one bounded fastcv_test target/module selection and classify markers.
# Inputs: validated target value and ALL or one validated module name.
# Output: emits bounded diagnostics through the common logger.
# Returns: 0 for functional PASS or 1 for FAIL.
# Side effects: creates a retained command log and records one testcase result.
run_fastcv_test_case() {
    rftc_target="$1"
    rftc_module="$2"
    case "$rftc_target" in
        0)
            rftc_target_name="all"
            ;;
        2)
            rftc_target_name="cpu"
            ;;
        4)
            rftc_target_name="venum"
            ;;
        6)
            rftc_target_name="cpu-venum"
            ;;
        8)
            rftc_target_name="dsp"
            ;;
    esac

    rftc_module_label=$(printf '%s\n' "$rftc_module" | tr '[:upper:]' '[:lower:]')
    rftc_log="$RESULT_DIR/fastcv_target-${rftc_target}_${rftc_target_name}_module-${rftc_module_label}.log"
    rm -f "$rftc_log"

    set -- \
        "$FASTCV_TEST_BINARY" \
        "$FASTCV_TEST_DATA_DIR" \
        -t "$rftc_target" \
        -l "$FASTCV_TEST_LOOPS"
    if [ "$rftc_module" = "ALL" ]; then
        set -- "$@" -L "$FASTCV_TEST_LEVEL"
        rftc_level_applied="$FASTCV_TEST_LEVEL"
    else
        set -- "$@" -m "$rftc_module"
        rftc_level_applied="not-applied"
    fi

    if [ -n "$FASTCV_TEST_FUNCTION" ]; then
        set -- "$@" -f "$FASTCV_TEST_FUNCTION"
    fi
    if [ -n "$FASTCV_TEST_OPERATION_MODE" ]; then
        set -- "$@" -M "$FASTCV_TEST_OPERATION_MODE"
    fi
    if [ "$FASTCV_TEST_OPERATION_TABLES_ONLY" -eq 1 ]; then
        set -- "$@" -OPT
    fi
    if [ -n "$FASTCV_TEST_SEED" ]; then
        set -- "$@" -s "$FASTCV_TEST_SEED"
    fi
    if [ "$FASTCV_TEST_NO_BUFFER_POOL" -eq 1 ]; then
        set -- "$@" -nbp
    fi
    if [ -n "$FASTCV_TEST_PREALLOC_BYTES" ]; then
        set -- "$@" -psb "$FASTCV_TEST_PREALLOC_BYTES"
    fi
    if [ "$FASTCV_TEST_OPENCV" -eq 1 ]; then
        set -- "$@" -o
    fi
    if [ "$FASTCV_TEST_UNIT_ONLY" -eq 1 ]; then
        set -- "$@" -U
    fi
    if [ "$FASTCV_TEST_PROFILE_ONLY" -eq 1 ]; then
        set -- "$@" -P
    fi
    if [ "$FASTCV_TEST_EXHAUSTIVE" -eq 1 ]; then
        set -- "$@" -E
    fi
    if [ -n "$FASTCV_TEST_RESOLUTION" ]; then
        set -- "$@" -S "$FASTCV_TEST_RESOLUTION"
    fi
    if [ "$FASTCV_TEST_QDSP_HEAP" -eq 1 ]; then
        set -- "$@" -H
    fi
    if [ "$FASTCV_TEST_ELEMENT_ALIGNMENT" -eq 1 ]; then
        set -- "$@" -AL
    fi
    if [ "$FASTCV_TEST_CACHE_FLUSH" -eq 1 ]; then
        set -- "$@" -C
    fi
    if [ "$FASTCV_TEST_WITHOUT_OPERATION_MODE" -eq 1 ]; then
        set -- "$@" -TWOp
    fi

    rftc_argc=$#
    if [ "$rftc_argc" -gt 14 ]; then
        test_result_record \
            "FAIL" \
            "fastcv_test argument selection exceeds the source limit, target=$rftc_target module=$rftc_module argc=$rftc_argc maximum=14"
        return 1
    fi

    log_info "[FASTCV-CASE] phase=start target=$rftc_target target_name=$rftc_target_name module=$rftc_module loops=$FASTCV_TEST_LOOPS level=$rftc_level_applied function=${FASTCV_TEST_FUNCTION:-all} operation_mode=${FASTCV_TEST_OPERATION_MODE:-default} operation_tables_only=$FASTCV_TEST_OPERATION_TABLES_ONLY seed=${FASTCV_TEST_SEED:-default} no_buffer_pool=$FASTCV_TEST_NO_BUFFER_POOL prealloc_bytes=${FASTCV_TEST_PREALLOC_BYTES:-none} opencv=$FASTCV_TEST_OPENCV unit_only=$FASTCV_TEST_UNIT_ONLY profile_only=$FASTCV_TEST_PROFILE_ONLY exhaustive=$FASTCV_TEST_EXHAUSTIVE resolution=${FASTCV_TEST_RESOLUTION:-default} qdsp_heap=$FASTCV_TEST_QDSP_HEAP element_alignment=$FASTCV_TEST_ELEMENT_ALIGNMENT cache_flush=$FASTCV_TEST_CACHE_FLUSH without_operation_mode=$FASTCV_TEST_WITHOUT_OPERATION_MODE argc=$rftc_argc timeout=${FASTCV_TEST_TIMEOUT}s"
    run_with_timeout_log \
        "$FASTCV_TEST_TIMEOUT" \
        "$rftc_log" \
        "$@"
    rftc_rc=$?

    log_file_with_label "FASTCV-TEST-$rftc_target-$rftc_module" "$rftc_log" 120
    if ! fastcv_collect_test_markers \
        "$rftc_log" \
        "$rftc_module" \
        "$FASTCV_TEST_FUNCTION" \
        "$FASTCV_TEST_WITHOUT_OPERATION_MODE"; then
        test_result_record \
            "FAIL" \
            "Could not parse fastcv_test evidence, target=$rftc_target module=$rftc_module artifact=$rftc_log"
        return 1
    fi
    rftc_failure_count="$FASTCV_MARKER_FAILURE_COUNT"
    rftc_fit_count="$FASTCV_MARKER_FIT_COUNT"
    rftc_profile_count="$FASTCV_MARKER_PROFILE_SUMMARY_COUNT"
    rftc_profile_case_count="$FASTCV_MARKER_PROFILE_CASE_PASS_COUNT"
    rftc_module_count="$FASTCV_MARKER_MODULE_COUNT"
    rftc_function_count="$FASTCV_MARKER_FUNCTION_COUNT"
    rftc_without_mode_count="$FASTCV_MARKER_WITHOUT_MODE_COUNT"
    rftc_output_bytes=$(wc -c <"$rftc_log" 2>/dev/null | tr -d '[:space:]')

    rftc_profile_required=1
    if [ "$FASTCV_TEST_UNIT_ONLY" -eq 1 ]; then
        rftc_profile_required=0
    fi
    rftc_marker_dialect="none"
    rftc_marker_missing=1
    if [ "$rftc_module_count" -gt 0 ] &&
       [ "$rftc_fit_count" -gt 0 ] &&
       { [ "$rftc_profile_required" -eq 0 ] ||
         [ "$rftc_profile_count" -gt 0 ]; }; then
        rftc_marker_dialect="test-and-profile"
        rftc_marker_missing=0
    elif [ "$rftc_profile_required" -eq 1 ] &&
         [ "$rftc_profile_case_count" -gt 0 ] &&
         [ "$rftc_profile_count" -gt 0 ]; then
        rftc_marker_dialect="profile-only"
        rftc_marker_missing=0
    fi
    if [ -n "$FASTCV_TEST_FUNCTION" ] && [ "$rftc_function_count" -eq 0 ]; then
        rftc_marker_missing=1
    fi
    if [ "$FASTCV_TEST_WITHOUT_OPERATION_MODE" -eq 1 ] &&
       [ "$rftc_without_mode_count" -eq 0 ]; then
        rftc_marker_missing=1
    fi

    log_info "[FASTCV-CASE] phase=complete target=$rftc_target target_name=$rftc_target_name module=$rftc_module rc=$rftc_rc marker_dialect=$rftc_marker_dialect module_pass_markers=$rftc_module_count fit_pass_markers=$rftc_fit_count profile_case_pass_markers=$rftc_profile_case_count profile_pass_markers=$rftc_profile_count profile_required=$rftc_profile_required function_markers=$rftc_function_count without_operation_mode_markers=$rftc_without_mode_count failure_markers=$rftc_failure_count output_bytes=${rftc_output_bytes:-0} artifact=$rftc_log"

    if [ "$rftc_rc" -ne 0 ]; then
        test_result_record \
            "FAIL" \
            "fastcv_test failed or exceeded the ${FASTCV_TEST_TIMEOUT}s bound, target=$rftc_target module=$rftc_module rc=$rftc_rc artifact=$rftc_log"
        return 1
    fi
    if [ "$rftc_failure_count" -gt 0 ]; then
        test_result_record \
            "FAIL" \
            "fastcv_test reported an official FAIL marker, target=$rftc_target module=$rftc_module failure_markers=$rftc_failure_count artifact=$rftc_log"
        return 1
    fi
    if [ "$rftc_marker_missing" -eq 1 ]; then
        test_result_record \
            "FAIL" \
            "fastcv_test omitted required PASS evidence, target=$rftc_target module=$rftc_module marker_dialect=$rftc_marker_dialect module_markers=$rftc_module_count fit_markers=$rftc_fit_count profile_case_markers=$rftc_profile_case_count profile_markers=$rftc_profile_count profile_required=$rftc_profile_required function_markers=$rftc_function_count without_operation_mode_markers=$rftc_without_mode_count artifact=$rftc_log"
        return 1
    fi

    test_result_record \
        "PASS" \
        "fastcv_test completed functional module validation, target=$rftc_target target_name=$rftc_target_name module=$rftc_module marker_dialect=$rftc_marker_dialect module_pass_markers=$rftc_module_count profile_case_pass_markers=$rftc_profile_case_count artifact=$rftc_log"
    return 0
}

parse_args "$@" || {
    usage >&2
    exit 2
}

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "FastCV module functional validation: running a user-sideloaded fastcv_test binary with its matching data folder"
log_info "[FASTCV-POLICY] applicability=explicit-external-fixture binary=${FASTCV_TEST_BINARY:-none} data_dir=${FASTCV_TEST_DATA_DIR:-none} targets=$FASTCV_TEST_TARGETS modules=$FASTCV_TEST_MODULES loops=$FASTCV_TEST_LOOPS level=$FASTCV_TEST_LEVEL timeout=${FASTCV_TEST_TIMEOUT}s max_cases=$FASTCV_TEST_MAX_CASES"
log_info "[FASTCV-OPTIONS] function=${FASTCV_TEST_FUNCTION:-all} operation_mode=${FASTCV_TEST_OPERATION_MODE:-default} operation_tables_only=$FASTCV_TEST_OPERATION_TABLES_ONLY seed=${FASTCV_TEST_SEED:-default} no_buffer_pool=$FASTCV_TEST_NO_BUFFER_POOL prealloc_bytes=${FASTCV_TEST_PREALLOC_BYTES:-none} opencv=$FASTCV_TEST_OPENCV unit_only=$FASTCV_TEST_UNIT_ONLY profile_only=$FASTCV_TEST_PROFILE_ONLY exhaustive=$FASTCV_TEST_EXHAUSTIVE resolution=${FASTCV_TEST_RESOLUTION:-default} qdsp_heap=$FASTCV_TEST_QDSP_HEAP element_alignment=$FASTCV_TEST_ELEMENT_ALIGNMENT cache_flush=$FASTCV_TEST_CACHE_FLUSH without_operation_mode=$FASTCV_TEST_WITHOUT_OPERATION_MODE"

if [ -z "$FASTCV_TEST_BINARY" ] && [ -z "$FASTCV_TEST_DATA_DIR" ]; then
    test_result_record \
        "SKIP" \
        "fastcv_test is a sideloaded fixture, provide both --binary PATH and --data-dir DIR"
    test_result_finish
fi
if [ -z "$FASTCV_TEST_BINARY" ] || [ -z "$FASTCV_TEST_DATA_DIR" ]; then
    test_result_record \
        "FAIL" \
        "FastCV fixture configuration is incomplete, binary=${FASTCV_TEST_BINARY:-missing} data_dir=${FASTCV_TEST_DATA_DIR:-missing}"
    test_result_finish
fi

case "$FASTCV_TEST_LOOPS" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "FastCV loop count must be a positive integer, observed=${FASTCV_TEST_LOOPS:-empty}"
        test_result_finish
        ;;
esac
case "$FASTCV_TEST_LEVEL" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "FastCV level must be a positive integer, observed=${FASTCV_TEST_LEVEL:-empty}"
        test_result_finish
        ;;
esac
case "$FASTCV_TEST_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "FastCV timeout must be a positive integer, observed=${FASTCV_TEST_TIMEOUT:-empty}"
        test_result_finish
        ;;
esac

if ! validate_boolean_option \
    "--operation-tables-only" \
    "$FASTCV_TEST_OPERATION_TABLES_ONLY" ||
   ! validate_boolean_option \
    "--no-buffer-pool" \
    "$FASTCV_TEST_NO_BUFFER_POOL" ||
   ! validate_boolean_option \
    "--opencv" \
    "$FASTCV_TEST_OPENCV" ||
   ! validate_boolean_option \
    "--unit-only" \
    "$FASTCV_TEST_UNIT_ONLY" ||
   ! validate_boolean_option \
    "--profile-only" \
    "$FASTCV_TEST_PROFILE_ONLY" ||
   ! validate_boolean_option \
    "--exhaustive" \
    "$FASTCV_TEST_EXHAUSTIVE" ||
   ! validate_boolean_option \
    "--qdsp-heap" \
    "$FASTCV_TEST_QDSP_HEAP" ||
   ! validate_boolean_option \
    "--element-alignment" \
    "$FASTCV_TEST_ELEMENT_ALIGNMENT" ||
   ! validate_boolean_option \
    "--cache-flush" \
    "$FASTCV_TEST_CACHE_FLUSH" ||
   ! validate_boolean_option \
    "--without-operation-mode" \
    "$FASTCV_TEST_WITHOUT_OPERATION_MODE"; then
    test_result_record \
        "FAIL" \
        "FastCV boolean option validation failed"
    test_result_finish
fi

case "$FASTCV_TEST_FUNCTION" in
    ''|*[!A-Za-z0-9_]*)
        if [ -n "$FASTCV_TEST_FUNCTION" ]; then
            test_result_record \
                "FAIL" \
                "FastCV function selector contains unsupported characters, function=$FASTCV_TEST_FUNCTION"
            test_result_finish
        fi
        ;;
esac
case "$FASTCV_TEST_OPERATION_MODE" in
    ''|0|1|2|3|4|5|6|7|8)
        ;;
    *)
        test_result_record \
            "FAIL" \
            "FastCV operation mode must be empty or 0 through 8, observed=$FASTCV_TEST_OPERATION_MODE"
        test_result_finish
        ;;
esac
if [ "$FASTCV_TEST_OPERATION_TABLES_ONLY" -eq 1 ] &&
   { [ -z "$FASTCV_TEST_OPERATION_MODE" ] ||
     [ "$FASTCV_TEST_OPERATION_MODE" -eq 0 ]; }; then
    test_result_record \
        "FAIL" \
        "FastCV operation-tables-only mode requires a nonzero --operation-mode"
    test_result_finish
fi
case "$FASTCV_TEST_SEED" in
    '')
        ;;
    -*)
        seed_digits=${FASTCV_TEST_SEED#-}
        case "$seed_digits" in
            ''|*[!0-9]*)
                test_result_record "FAIL" "FastCV seed must be an integer, observed=$FASTCV_TEST_SEED"
                test_result_finish
                ;;
        esac
        ;;
    *[!0-9]*)
        test_result_record "FAIL" "FastCV seed must be an integer, observed=$FASTCV_TEST_SEED"
        test_result_finish
        ;;
esac
case "$FASTCV_TEST_PREALLOC_BYTES" in
    '')
        ;;
    *[!0-9]*|0)
        test_result_record \
            "FAIL" \
            "FastCV preallocation size must be a positive integer, observed=$FASTCV_TEST_PREALLOC_BYTES"
        test_result_finish
        ;;
esac
case "$FASTCV_TEST_RESOLUTION" in
    ''|0|1|2|3|4|5|6|7)
        ;;
    *)
        test_result_record \
            "FAIL" \
            "FastCV resolution selector must be empty or 0 through 7, observed=$FASTCV_TEST_RESOLUTION"
        test_result_finish
        ;;
esac
if [ "$FASTCV_TEST_UNIT_ONLY" -eq 1 ] &&
   [ "$FASTCV_TEST_PROFILE_ONLY" -eq 1 ]; then
    test_result_record \
        "FAIL" \
        "FastCV unit-only and profile-only modes cannot be enabled together"
    test_result_finish
fi
if [ "$FASTCV_TEST_NO_BUFFER_POOL" -eq 1 ] &&
   [ -n "$FASTCV_TEST_PREALLOC_BYTES" ]; then
    test_result_record \
        "FAIL" \
        "FastCV preallocated buffer bytes cannot be combined with no-buffer-pool mode"
    test_result_finish
fi

if [ ! -e "$FASTCV_TEST_BINARY" ]; then
    test_result_record \
        "FAIL" \
        "Sideloaded fastcv_test binary does not exist, binary=$FASTCV_TEST_BINARY"
    test_result_finish
fi
if [ ! -f "$FASTCV_TEST_BINARY" ]; then
    test_result_record \
        "FAIL" \
        "Sideloaded fastcv_test binary path is not a regular file, binary=$FASTCV_TEST_BINARY"
    test_result_finish
fi
if [ ! -x "$FASTCV_TEST_BINARY" ]; then
    test_result_record \
        "FAIL" \
        "Sideloaded fastcv_test binary is not executable, binary=$FASTCV_TEST_BINARY"
    test_result_finish
fi
if [ ! -d "$FASTCV_TEST_DATA_DIR" ]; then
    test_result_record \
        "FAIL" \
        "Sideloaded FastCV data path is not a directory, data_dir=$FASTCV_TEST_DATA_DIR"
    test_result_finish
fi
if [ ! -r "$FASTCV_TEST_DATA_DIR" ]; then
    test_result_record \
        "FAIL" \
        "Sideloaded FastCV data directory is not readable, data_dir=$FASTCV_TEST_DATA_DIR"
    test_result_finish
fi

CONTROL_TABLE="$FASTCV_TEST_DATA_DIR/FastCVTestTable.csv"
if [ ! -r "$CONTROL_TABLE" ]; then
    test_result_record \
        "FAIL" \
        "Sideloaded FastCV data directory is missing the readable FastCVTestTable.csv control file, expected=$CONTROL_TABLE"
    test_result_finish
fi

fastcv_prepare_runtime_packages
fastcv_package_rc=$?
case "$fastcv_package_rc" in
    0|2)
        ;;
    *)
        test_result_record \
            "FAIL" \
            "FastCV runtime package preparation failed, os=$(pkg_detect_os_id) set=fastcv-runtime"
        test_result_finish
        ;;
esac

if ! find "$FASTCV_TEST_DATA_DIR" -type f -print >"$DATA_REPORT" 2>/dev/null; then
    test_result_record \
        "FAIL" \
        "Could not enumerate the sideloaded FastCV data directory, data_dir=$FASTCV_TEST_DATA_DIR artifact=$DATA_REPORT"
    test_result_finish
fi
data_file_count=$(wc -l <"$DATA_REPORT" 2>/dev/null | tr -d '[:space:]')
if [ "${data_file_count:-0}" -eq 0 ]; then
    test_result_record \
        "FAIL" \
        "Sideloaded FastCV data directory contains no files, data_dir=$FASTCV_TEST_DATA_DIR artifact=$DATA_REPORT"
    test_result_finish
fi

{
    printf 'binary=%s\n' "$FASTCV_TEST_BINARY"
    printf 'architecture=%s\n' "$(uname -m 2>/dev/null || printf 'unknown')"
    ls -l "$FASTCV_TEST_BINARY" 2>&1
} >"$BINARY_REPORT"
log_info "[FASTCV-FIXTURE] binary=$FASTCV_TEST_BINARY executable=1 data_dir=$FASTCV_TEST_DATA_DIR control_table=$CONTROL_TABLE control_table_readable=1 data_files=$data_file_count binary_artifact=$BINARY_REPORT data_artifact=$DATA_REPORT"
log_file_with_label "FASTCV-BINARY" "$BINARY_REPORT" 10
log_file_with_label "FASTCV-DATA" "$DATA_REPORT" 12

if ! prepare_target_list "$FASTCV_TEST_TARGETS" "$TARGET_LIST"; then
    test_result_record \
        "FAIL" \
        "FastCV target selection is invalid, requested=${FASTCV_TEST_TARGETS:-empty} accepted=0,2,4,6,8 artifact=$TARGET_LIST"
    test_result_finish
fi
if ! prepare_module_list "$FASTCV_TEST_MODULES" "$MODULE_LIST"; then
    test_result_record \
        "FAIL" \
        "FastCV module selection is invalid, requested=${FASTCV_TEST_MODULES:-empty} artifact=$MODULE_LIST"
    test_result_finish
fi
log_file_with_label "FASTCV-TARGET" "$TARGET_LIST" 10
log_file_with_label "FASTCV-MODULE" "$MODULE_LIST" 80

if grep -Fxq "0" "$TARGET_LIST" 2>/dev/null &&
   grep -Fxq "ALL" "$MODULE_LIST" 2>/dev/null; then
    log_warn "[FASTCV-SELECTION] mode=full-target-full-module runtime=potentially-long output=replayed-after-completion timeout=${FASTCV_TEST_TIMEOUT}s"
fi

target_count=$(wc -l <"$TARGET_LIST" 2>/dev/null | tr -d '[:space:]')
module_count=$(wc -l <"$MODULE_LIST" 2>/dev/null | tr -d '[:space:]')
if [ -n "$FASTCV_TEST_FUNCTION" ]; then
    selected_module=$(sed -n '1p' "$MODULE_LIST")
    if [ "$module_count" -ne 1 ] || [ "$selected_module" = "ALL" ]; then
        test_result_record \
            "FAIL" \
            "FastCV function selection requires exactly one focused module, function=$FASTCV_TEST_FUNCTION requested_modules=$FASTCV_TEST_MODULES normalized_modules=$module_count"
        test_result_finish
    fi
fi
case_count=$((target_count * module_count))
if [ "$case_count" -gt "$FASTCV_TEST_MAX_CASES" ]; then
    test_result_record \
        "FAIL" \
        "FastCV selection exceeds the bounded invocation limit, requested=$case_count maximum=$FASTCV_TEST_MAX_CASES targets=$target_count modules=$module_count"
    test_result_finish
fi
log_info "[FASTCV-SELECTION] targets=$target_count modules=$module_count invocations=$case_count dsp_target_selected=$DSP_TARGET_SELECTED target_artifact=$TARGET_LIST module_artifact=$MODULE_LIST"

while IFS= read -r fastcv_target; do
    while IFS= read -r fastcv_module; do
        run_fastcv_test_case "$fastcv_target" "$fastcv_module" || true
    done <"$MODULE_LIST"
done <"$TARGET_LIST"

if [ "$DSP_TARGET_SELECTED" -eq 1 ]; then
    KERNEL_LOG_JOURNAL_FALLBACK=1
    export KERNEL_LOG_JOURNAL_FALLBACK
    scan_dmesg_errors \
        "$RESULT_DIR/kernel" \
        "fastrpc|adsprpc|cdsprpc" \
        "not a crash|subsys-restart"
    dmesg_rc=$?

    if [ "${DMESG_ACCESS_STATUS:-unknown}" != "available" ]; then
        test_result_record \
            "SKIP" \
            "Kernel log access is unavailable for FastCV DSP health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=${DMESG_ACCESS_LOG:-$RESULT_DIR/kernel/dmesg_access.log}"
    elif [ "$dmesg_rc" -eq 0 ]; then
        test_result_record \
            "FAIL" \
            "FastRPC-related kernel errors were found during FastCV DSP validation, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
    else
        test_result_record \
            "PASS" \
            "No persistent FastRPC kernel errors were found during FastCV DSP validation"
    fi
else
    log_info "[FASTCV-KERNEL] action=not-required reason=no-dsp-capable-target-selected"
fi

test_result_finish
