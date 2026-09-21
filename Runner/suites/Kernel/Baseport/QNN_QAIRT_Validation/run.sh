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
TESTNAME="QNN_QAIRT_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

QNN_TIMEOUT="${QNN_TIMEOUT:-60}"
QNN_ORT_LIBRARY="${QNN_ORT_LIBRARY:-}"
QNN_PLUGIN_LIBRARY="${QNN_PLUGIN_LIBRARY:-}"
QNN_ORT_LIBRARY_SOURCE="dynamic"
QNN_PLUGIN_LIBRARY_SOURCE="dynamic"
if [ -n "$QNN_ORT_LIBRARY" ]; then
    QNN_ORT_LIBRARY_SOURCE="environment"
fi
if [ -n "$QNN_PLUGIN_LIBRARY" ]; then
    QNN_PLUGIN_LIBRARY_SOURCE="environment"
fi

RESULT_DIR="$SCRIPT_DIR/results/$TESTNAME/run-$(date '+%Y%m%d-%H%M%S')-$$"
RUN_LOG="$RESULT_DIR/qnn_inference.log"
REPORT_FILE="$RESULT_DIR/qnn_inference.tsv"
MODEL_FILE="$RESULT_DIR/qnn_qdq_add.onnx"

# usage
# Takes no arguments, prints the supported CLI contract to stdout, returns 0,
# and has no target-side effects.
usage() {
    printf '%s\n' \
        "Usage: ./run.sh [options]" \
        "  --timeout SECONDS        Inference watchdog, default: 60" \
        "  --ort-library PATH       Override libonnxruntime discovery" \
        "  --qnn-plugin PATH        Override libonnxruntime_providers_qnn discovery" \
        "  -h, --help" \
        "The test always selects QNNExecutionProvider with backend_type=htp and disables CPU EP fallback." \
        "CLI options override environment variables. Empty library paths use dynamic discovery."
}

# parse_args <suite-arguments...>
# Applies CLI values and source provenance to suite globals. It emits no stdout,
# returns 0 on success or 2 for an invalid argument, and does not probe or mutate
# the target runtime.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --timeout)
                [ "$#" -ge 2 ] || return 2
                QNN_TIMEOUT="$2"
                shift 2
                ;;
            --ort-library)
                [ "$#" -ge 2 ] || return 2
                QNN_ORT_LIBRARY="$2"
                if [ -n "$QNN_ORT_LIBRARY" ]; then
                    QNN_ORT_LIBRARY_SOURCE="cli"
                else
                    QNN_ORT_LIBRARY_SOURCE="dynamic"
                fi
                shift 2
                ;;
            --qnn-plugin)
                [ "$#" -ge 2 ] || return 2
                QNN_PLUGIN_LIBRARY="$2"
                if [ -n "$QNN_PLUGIN_LIBRARY" ]; then
                    QNN_PLUGIN_LIBRARY_SOURCE="cli"
                else
                    QNN_PLUGIN_LIBRARY_SOURCE="dynamic"
                fi
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

parse_args "$@" || {
    usage >&2
    exit 2
}

test_result_init "$TESTNAME" "$RES_FILE" || exit 1
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create retained evidence directory $RESULT_DIR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Evidence directory: $RESULT_DIR"
log_info "QNN/QAIRT validation: running deterministic ONNX Runtime inference on the QNN HTP backend with CPU EP fallback disabled"
log_info "[QNN-POLICY] provider=QNNExecutionProvider backend=htp cpu_fallback=disabled graph_io_quantization=qnn timeout=${QNN_TIMEOUT}s ort_library=${QNN_ORT_LIBRARY:-auto} ort_source=$QNN_ORT_LIBRARY_SOURCE qnn_plugin=${QNN_PLUGIN_LIBRARY:-auto} qnn_source=$QNN_PLUGIN_LIBRARY_SOURCE network=not-required"

case "$QNN_TIMEOUT" in
    ''|*[!0-9]*|0)
        test_result_record "FAIL" "QNN configuration is invalid, timeout must be a positive integer"
        test_result_finish
        ;;
esac

PYTHON_COMMAND=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_COMMAND=$(command -v python3)
elif command -v python >/dev/null 2>&1 &&
     python -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' \
        >/dev/null 2>&1; then
    PYTHON_COMMAND=$(command -v python)
fi

if [ -z "$PYTHON_COMMAND" ]; then
    test_result_record "SKIP" "Image-provided Python 3 is unavailable, the dependency-free ONNX Runtime C API client cannot run"
    test_result_finish
fi

log_info "[QNN-DISCOVERY] python=$PYTHON_COMMAND architecture=$(uname -m 2>/dev/null || printf '%s' unknown) runner=$TOOLS/qnn_ort_runner.py"
run_with_timeout_log \
    "$QNN_TIMEOUT" \
    "$RUN_LOG" \
    "$PYTHON_COMMAND" "$TOOLS/qnn_ort_runner.py" \
        --ort-library "$QNN_ORT_LIBRARY" \
        --qnn-plugin "$QNN_PLUGIN_LIBRARY" \
        --model-file "$MODEL_FILE" \
        --report-file "$REPORT_FILE"
runner_rc=$?

log_file_with_label "QNN-INFERENCE" "$RUN_LOG" 40
log_file_with_label "QNN-REPORT" "$REPORT_FILE" 40
runner_status="missing"
if [ -r "$REPORT_FILE" ]; then
    runner_status=$(
        sed -n 's/^status[[:space:]]//p' "$REPORT_FILE" 2>/dev/null |
            head -n 1
    )
    [ -n "$runner_status" ] || runner_status="missing"
fi
model_bytes=0
if [ -r "$MODEL_FILE" ]; then
    model_bytes=$(wc -c <"$MODEL_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$model_bytes" in
        ''|*[!0-9]*)
            model_bytes=0
            ;;
    esac
fi
log_info "[QNN-RESULT] runner_rc=$runner_rc report_status=$runner_status model_bytes=$model_bytes report=$REPORT_FILE model=$MODEL_FILE"

case "$runner_rc" in
    0)
        if [ "$runner_status" = "PASS" ] && [ -s "$MODEL_FILE" ]; then
            test_result_record "PASS" "ONNX Runtime completed deterministic QNN HTP inference with CPU fallback disabled and exact output validation, report=$REPORT_FILE model=$MODEL_FILE"
        else
            test_result_record "FAIL" "QNN runner returned success without complete PASS evidence, report_status=$runner_status model_bytes=$model_bytes artifact=$RUN_LOG report=$REPORT_FILE"
        fi
        ;;
    2)
        if [ "$runner_status" = "SKIP" ]; then
            test_result_record "SKIP" "ONNX Runtime or its QNN execution-provider plugin is not installed, artifact=$RUN_LOG report=$REPORT_FILE"
            test_result_finish
        else
            test_result_record "FAIL" "QNN runner exited with status 2 without a validated SKIP report, report_status=$runner_status artifact=$RUN_LOG report=$REPORT_FILE"
        fi
        ;;
    *)
        test_result_record "FAIL" "QNN HTP inference failed or exceeded the ${QNN_TIMEOUT}s watchdog, rc=$runner_rc artifact=$RUN_LOG report=$REPORT_FILE"
        ;;
esac

export KERNEL_LOG_JOURNAL_FALLBACK=1
scan_dmesg_errors \
    "$RESULT_DIR/kernel" \
    'qnn|qairt|fastrpc|adsprpc|cdsprpc|remoteproc|qcom_q6v5|qcom_scm|iommu' \
    'dummy regulator|supply [^ ]+ not found|using dummy regulator'
dmesg_rc=$?
if [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" "Kernel log access is unavailable for QNN/QAIRT health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/kernel/dmesg_access.log"
elif [ "$dmesg_rc" -eq 0 ]; then
    log_file_with_label "QNN-KERNEL-ERROR" "$RESULT_DIR/kernel/dmesg_errors.log" 25
    test_result_record "FAIL" "QNN, FastRPC, remoteproc, or IOMMU kernel errors were detected, artifact=$RESULT_DIR/kernel/dmesg_errors.log"
else
    test_result_record "PASS" "No persistent QNN, FastRPC, remoteproc, or IOMMU kernel errors were found"
fi

test_result_finish
