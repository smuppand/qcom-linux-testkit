#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# --- Robustly find and source init_env ---------------------------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

TESTNAME="Camera_RDI_FrameCapture"
RES_FILE="./$TESTNAME.res"

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
    echo "$TESTNAME FAIL" >"$RES_FILE" 2>/dev/null || true
    exit 1
fi

REPO_ROOT="$(dirname "$INIT_ENV")"

# Only source once.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

# --------- Camera RDI helper library ---------
CAMERA_RDI_LIB=""

if [ -n "${TOOLS:-}" ] && [ -f "$TOOLS/camera/lib_camera_rdi.sh" ]; then
    CAMERA_RDI_LIB="$TOOLS/camera/lib_camera_rdi.sh"
elif [ -n "${ROOT_DIR:-}" ] && [ -f "$ROOT_DIR/utils/camera/lib_camera_rdi.sh" ]; then
    CAMERA_RDI_LIB="$ROOT_DIR/utils/camera/lib_camera_rdi.sh"
elif [ -n "${REPO_ROOT:-}" ] && [ -f "$REPO_ROOT/utils/camera/lib_camera_rdi.sh" ]; then
    CAMERA_RDI_LIB="$REPO_ROOT/utils/camera/lib_camera_rdi.sh"
else
    echo "[ERROR] Missing camera RDI helper library" >&2
    echo "[ERROR] Checked:" >&2
    echo "[ERROR] ${TOOLS:-<TOOLS unset>}/camera/lib_camera_rdi.sh" >&2
    echo "[ERROR] ${ROOT_DIR:-<ROOT_DIR unset>}/utils/camera/lib_camera_rdi.sh" >&2
    echo "[ERROR] ${REPO_ROOT:-<REPO_ROOT unset>}/utils/camera/lib_camera_rdi.sh" >&2
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
fi

log_info "Using camera RDI helper library: $CAMERA_RDI_LIB"

# shellcheck disable=SC1090
. "$CAMERA_RDI_LIB"

test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

print_usage() {
    cat <<EOF
Usage: $0 [--format <v4l2_fmt1,v4l2_fmt2,...>] [--frames <count>] [--help]

Options:
  --format <v4l2_fmt1,v4l2_fmt2,...> Test one or more comma-separated formats, for example: UYVY,NV12
  --frames <count> Number of frames to capture per pipeline. Default: 10
  --help Show this help message

Environment:
  CAPTURE_TIMEOUT_SECS YAVTA capture timeout per attempt. Default: 45
  YAVTA_CTRL_TIMEOUT_SECS YAVTA stream-control timeout. Default: 10
EOF
}

log_info "----------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------"
log_info "=== Test Initialization ==="

# --------- Argument Parsing ---------
USER_FORMAT=""
FRAMES=10

while [ $# -gt 0 ]; do
    case "$1" in
        --format)
            shift
            USER_FORMAT="$1"
            ;;
        --frames)
            shift
            FRAMES="$1"
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            print_usage
            echo "$TESTNAME FAIL" >"$RES_FILE"
            exit 1
            ;;
    esac
    shift
done

case "$FRAMES" in
    ''|*[!0-9]*)
        log_warn "Invalid --frames value; using default 10"
        FRAMES=10
        ;;
esac

CAPTURE_TIMEOUT_SECS="${CAPTURE_TIMEOUT_SECS:-45}"
case "$CAPTURE_TIMEOUT_SECS" in
    ''|*[!0-9]*)
        CAPTURE_TIMEOUT_SECS=45
        ;;
esac

# --------- DT Precheck ---------
if ! dt_confirm_node_or_compatible "isp" "cam" "camss"; then
    log_skip "$TESTNAME SKIP – No ISP/camera node/compatible found in DT"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 2
fi

# --------- Kernel config sanity ---------
log_info "[CONFIG] Expect at least: CONFIG_VIDEO_QCOM_CAMSS=y (or =m)"
check_kernel_config "CONFIG_VIDEO_QCOM_CAMSS CONFIG_MEDIA_CONTROLLER CONFIG_V4L2_FWNODE" \
  || log_warn "[CONFIG] One or more options missing; will continue if CAMSS stack is otherwise present"

# Optional visibility: print platform CAMCC entries.
# CAMCC symbol names vary by platform, so do not hardcode SC7280 here.
if command -v zgrep >/dev/null 2>&1; then
    CAMCC_SYMS="$(zgrep -E '^CONFIG_.*CAMCC.*=(y|m)' /proc/config.gz 2>/dev/null || true)"
else
    CAMCC_SYMS="$(gzip -dc /proc/config.gz 2>/dev/null | grep -E '^CONFIG_.*CAMCC.*=(y|m)' || true)"
fi

if [ -n "$CAMCC_SYMS" ]; then
    log_pass "[CONFIG] CAMCC config present:"
    printf '%s\n' "$CAMCC_SYMS" | while IFS= read -r s; do
        [ -n "$s" ] && log_info "[CONFIG] $s"
    done
else
    log_warn "[CONFIG] No CAMCC config symbol found; continuing if CAMSS/media nodes are present"
fi

# --------- Broader readiness gate ---------
DMESG_CACHE="$(dmesg 2>/dev/null || true)"

if [ -e /dev/media0 ] || [ -e /dev/video0 ]; then
    log_pass "[READY] Media/video nodes present:"
    for f in /dev/media* /dev/video*; do
        [ -e "$f" ] || continue
        log_info " - $f"
    done
elif is_module_loaded qcom_camss; then
    log_pass "[READY] qcom_camss module loaded"
elif [ -d /sys/module/qcom_camss ]; then
    log_pass "[READY] qcom_camss present as builtin"
elif printf '%s\n' "$DMESG_CACHE" | grep -qiE 'qcom[-_]camss'; then
    log_info "[READY] CAMSS messages found in dmesg, likely builtin"
else
    log_skip "$TESTNAME SKIP – CAMSS driver not present, module or built-in"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 2
fi

# --------- Module inventory ---------
MODULES_LIST="qcom_camss videodev mc v4l2_fwnode v4l2_async videobuf2_common videobuf2_v4l2 videobuf2_dma_contig videobuf2_dma_sg videobuf2_memops"

CAMCC_MODULES="$(awk '{print $1}' /proc/modules 2>/dev/null | grep -E 'camcc|cam_cc|glymur_camcc|kaanapali_camcc|sc7280_camcc|camcc_sc7280' | tr '\n' ' ')"
if [ -n "$CAMCC_MODULES" ]; then
    MODULES_LIST="$MODULES_LIST $CAMCC_MODULES"
fi

present_mods=""
builtin_mods=""
missing_mods=""

for m in $MODULES_LIST; do
    if is_module_loaded "$m"; then
        present_mods="$present_mods $m"
    elif [ -d "/sys/module/$m" ]; then
        builtin_mods="$builtin_mods $m"
    else
        missing_mods="$missing_mods $m"
    fi
done

if [ -n "$present_mods" ]; then
    log_pass "[MODULES] Loaded:"
    for m in $present_mods; do
        [ -n "$m" ] && log_info " - $m"
    done
fi

if [ -n "$builtin_mods" ]; then
    log_info "[MODULES] Built-in:"
    for m in $builtin_mods; do
        [ -n "$m" ] && log_info " - $m"
    done
fi

if [ -n "$missing_mods" ]; then
    log_warn "[MODULES] Not found:"
    for m in $missing_mods; do
        [ -n "$m" ] && log_info " - $m"
    done
fi

# Sensor modules, best-effort.
SENSOR_MODS="$(awk '{print $1}' /proc/modules 2>/dev/null | grep -E '^(imx|ov|gc|ar)[0-9]+' | tr '\n' ' ')"
if [ -n "$SENSOR_MODS" ]; then
    log_info "[MODULES] Sensors:"
    for s in $SENSOR_MODS; do
        log_info " - $s"
    done
fi

# --------- Dmesg probe errors ---------
DRIVER_MOD="qcom_camss"
DMESG_MODULES='qcom_camss|camss|isp'
DMESG_EXCLUDE='dummy regulator|supply [^ ]+ not found|using dummy regulator|Failed to create device link|reboot-mode.*-EEXIST|can.t register reboot mode'

if scan_dmesg_errors "$SCRIPT_DIR" "$DMESG_MODULES" "$DMESG_EXCLUDE"; then
    log_skip "$TESTNAME SKIP – $DRIVER_MOD probe errors detected in dmesg"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 2
fi

# --------- Dependency Checks ---------
check_dependencies media-ctl yavta python3 v4l2-ctl || {
    log_skip "$TESTNAME SKIP – Required tools missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 2
}

# --------- Media Node / Pipeline Detection ---------
DEBUG_DIR="./${TESTNAME}_debug"
mkdir -p "$DEBUG_DIR" 2>/dev/null || true

TMP_PIPELINES_FILE="$(mktemp "/tmp/${TESTNAME}_blocks.XXXXXX")"
trap 'rm -f "$TMP_PIPELINES_FILE"' EXIT

MEDIA_NODE=""
PYTHON_PIPELINES=""
TOPO_FILE=""
PARSER_OUT_FILE=""
CANDIDATE_MEDIA_NODES=""
FINAL_MEDIA_NODES=""

# Some boards expose the real CAMSS graph on /dev/media1 or later.
# Some LAVA boots may create media nodes slightly late, so retry discovery.
DISCOVERY_ATTEMPT=1
while [ "$DISCOVERY_ATTEMPT" -le 5 ]; do
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=5 >/dev/null 2>&1 || true
    fi

    CANDIDATE_MEDIA_NODES="$(detect_media_node 2>/dev/null || true)"

    for m in /dev/media*; do
        [ -e "$m" ] || continue

        case " $CANDIDATE_MEDIA_NODES " in
            *" $m "*) ;;
            *) CANDIDATE_MEDIA_NODES="$CANDIDATE_MEDIA_NODES $m" ;;
        esac
    done

    if [ -n "$CANDIDATE_MEDIA_NODES" ]; then
        FINAL_MEDIA_NODES="$CANDIDATE_MEDIA_NODES"
        log_info "Candidate media nodes attempt $DISCOVERY_ATTEMPT: $CANDIDATE_MEDIA_NODES"
    else
        log_info "Candidate media nodes attempt $DISCOVERY_ATTEMPT: <none>"
    fi

    for candidate in $CANDIDATE_MEDIA_NODES; do
        [ -e "$candidate" ] || continue

        candidate_base="$(basename "$candidate")"
        CANDIDATE_TOPO_FILE="$DEBUG_DIR/topology_${candidate_base}.txt"
        CANDIDATE_PARSER_OUT_FILE="$DEBUG_DIR/parser_output_${candidate_base}.txt"
        CANDIDATE_MEDIA_CTL_ERR_FILE="$DEBUG_DIR/media_ctl_${candidate_base}.err"

        log_info "Checking media node for RDI pipeline: $candidate"

        media-ctl -d "$candidate" -r >/dev/null 2>&1 || true
        log_info "Media graph reset (-r) done on $candidate"
        sleep 0.2

        media-ctl -p -d "$candidate" >"$CANDIDATE_TOPO_FILE" 2>"$CANDIDATE_MEDIA_CTL_ERR_FILE"
        MEDIA_CTL_RC=$?

        if [ "$MEDIA_CTL_RC" -ne 0 ] || [ ! -s "$CANDIDATE_TOPO_FILE" ]; then
            log_warn "Skipping $candidate: failed to dump media topology"
            log_info "[DEBUG] media-ctl rc for $candidate: $MEDIA_CTL_RC"
            log_info "[DEBUG] media-ctl stderr saved: $CANDIDATE_MEDIA_CTL_ERR_FILE"

            if [ -s "$CANDIDATE_MEDIA_CTL_ERR_FILE" ]; then
                while IFS= read -r line; do
                    [ -n "$line" ] && log_info "[MEDIA-CTL:$candidate_base] $line"
                done <"$CANDIDATE_MEDIA_CTL_ERR_FILE"
            fi

            continue
        fi

        CANDIDATE_PIPELINES="$(run_camera_pipeline_parser "$CANDIDATE_TOPO_FILE" 2>&1)"
        PARSER_RC=$?
        printf '%s\n' "$CANDIDATE_PIPELINES" >"$CANDIDATE_PARSER_OUT_FILE"

        if [ "$PARSER_RC" -eq 0 ] && grep -q -e '^--$' "$CANDIDATE_PARSER_OUT_FILE"; then
            MEDIA_NODE="$candidate"
            PYTHON_PIPELINES="$CANDIDATE_PIPELINES"
            TOPO_FILE="$CANDIDATE_TOPO_FILE"
            PARSER_OUT_FILE="$CANDIDATE_PARSER_OUT_FILE"

            log_info "Selected media node for RDI pipeline: $MEDIA_NODE"
            break
        fi

        log_warn "Candidate $candidate has no valid RDI pipeline; trying next media node"
        log_info "[DEBUG] Parser rc for $candidate: $PARSER_RC"
        log_info "[DEBUG] Topology saved: $CANDIDATE_TOPO_FILE"
        log_info "[DEBUG] Parser output saved: $CANDIDATE_PARSER_OUT_FILE"

        if [ -s "$CANDIDATE_PARSER_OUT_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && log_info "[PARSER:$candidate_base candidate-only] $line"
            done <"$CANDIDATE_PARSER_OUT_FILE"
        else
            log_info "[PARSER:$candidate_base candidate-only] <empty>"
        fi
    done

    if [ -n "$MEDIA_NODE" ]; then
        break
    fi

    DISCOVERY_ATTEMPT=$((DISCOVERY_ATTEMPT + 1))

    if [ "$DISCOVERY_ATTEMPT" -le 5 ]; then
        log_info "No valid RDI pipeline found yet; rescanning media nodes"
        sleep 1
    fi
done

if [ -z "$FINAL_MEDIA_NODES" ]; then
    log_skip "$TESTNAME SKIP – Media node not found"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 2
fi

if [ -z "$MEDIA_NODE" ] || [ -z "$PYTHON_PIPELINES" ]; then
    log_skip "$TESTNAME SKIP – No valid RDI pipelines found on any media node"
    log_info "[DEBUG] Final media node list checked: $FINAL_MEDIA_NODES"

    for media in $FINAL_MEDIA_NODES; do
        media_base="$(basename "$media")"
        media_topo="$DEBUG_DIR/topology_${media_base}.txt"
        media_parser="$DEBUG_DIR/parser_output_${media_base}.txt"

        if [ -f "$media_parser" ]; then
            log_info "[DEBUG] Parser output for $media:"
            if [ -s "$media_parser" ]; then
                while IFS= read -r line; do
                    [ -n "$line" ] && log_info "[PARSER:$media_base final] $line"
                done <"$media_parser"
            else
                log_info "[PARSER:$media_base final] <empty>"
            fi
        fi

        if [ -f "$media_topo" ]; then
            log_info "[DEBUG] Topology summary for $media:"
            grep -E '^- entity |device node name|type V4L2 subdev subtype Sensor|pad[0-9]+:|fmt:' "$media_topo" 2>/dev/null \
                | head -n 240 \
                | while IFS= read -r line; do
                    log_info "[TOPO:$media_base] $line"
                done
        fi
    done

    log_info "[DEBUG] Video device inventory:"
    for vdev in /dev/video*; do
        [ -e "$vdev" ] || continue

        vdev_info="$(v4l2-ctl -d "$vdev" -D 2>/dev/null || true)"

        v4l2_driver="$(
            printf '%s\n' "$vdev_info" \
                | sed -n 's/^[[:space:]]*Driver name[[:space:]]*:[[:space:]]*//p' \
                | head -n 1
        )"

        v4l2_card="$(
            printf '%s\n' "$vdev_info" \
                | sed -n 's/^[[:space:]]*Card type[[:space:]]*:[[:space:]]*//p' \
                | head -n 1
        )"

        log_info "[VDEV] $vdev driver=${v4l2_driver:-unknown} card=${v4l2_card:-unknown}"
    done

    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 2
fi

printf '%s\n' "$PYTHON_PIPELINES" >"$TMP_PIPELINES_FILE"

log_info "Detected media node: $MEDIA_NODE"
log_info "Topology saved: $TOPO_FILE"
log_info "Parser output saved: $PARSER_OUT_FILE"
log_info "User format override: ${USER_FORMAT:-<none>}"
log_info "Frame count per pipeline: $FRAMES"
log_info "YAVTA capture timeout per attempt: ${CAPTURE_TIMEOUT_SECS:-45}s"

# --------- Pipeline Processing ---------
PASS=0
FAIL=0
SKIP=0
COUNT=0
block=""

while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "--" ]; then
        COUNT=$((COUNT + 1))
        TMP="/tmp/cam_block.$$.$COUNT"
        printf '%s\n' "$block" >"$TMP"

        # Parses block and sets SENSOR, VIDEO, YAVTA_DEV, YAVTA_FMT,
        # MEDIA_CTL_V_LIST, MEDIA_CTL_L_LIST, YAVTA_W, YAVTA_H, etc.
        parse_pipeline_block "$TMP"
        rm -f "$TMP"

        if [ -z "$VIDEO" ] || [ "$VIDEO" = "None" ] || [ -z "$YAVTA_DEV" ]; then
            log_skip "${SENSOR:-unknown}: Invalid pipeline – skipping"
            SKIP=$((SKIP + 1))
            block=""
            continue
        fi

        FORMATS_LIST="$USER_FORMAT"
        [ -z "$FORMATS_LIST" ] && FORMATS_LIST="$YAVTA_FMT"

        OLD_IFS="$IFS"
        IFS=','

        for FMT_OVERRIDE in $FORMATS_LIST; do
            camera_rdi_prepare_format_iteration "$FMT_OVERRIDE" "$YAVTA_FMT"

            log_info "----- Pipeline $COUNT: ${SENSOR:-unknown} $VIDEO [pads:$PAD_MBUS_FMT] [video:$TARGET_FORMAT] -----"

            camera_rdi_begin_result_tracking

            print_planned_commands "$MEDIA_NODE" "$TARGET_FORMAT"

            configure_pipeline_block "$MEDIA_NODE" "$TARGET_FORMAT"
            camera_rdi_capture_attempt "$FRAMES" "$TARGET_FORMAT"
            RET=$?

            # Safety retry only for capture failure, not unsupported/missing/interrupted.
            if [ "$RET" -eq 1 ]; then
                log_warn "First attempt failed; resetting media graph and retrying once"
                camera_rdi_reset_media_graph "$MEDIA_NODE"

                print_planned_commands "$MEDIA_NODE" "$TARGET_FORMAT"
                configure_pipeline_block "$MEDIA_NODE" "$TARGET_FORMAT"
                camera_rdi_capture_attempt "$FRAMES" "$TARGET_FORMAT"
                RET=$?
            fi

            ######################## Format fallback ########################
            if [ "$RET" -eq 1 ]; then
                if printf '%s' "$TARGET_FORMAT" | grep -q 'P$'; then
                    ALT_FMT_A="$(printf '%s' "$TARGET_FORMAT" | sed 's/P$//')"
                    ALT_MBUS_A="$(camera_rdi_video_fmt_to_mbus_fmt "$ALT_FMT_A")"

                    SAVE_V="$MEDIA_CTL_V_LIST"
                    SAVE_W="$YAVTA_W"
                    SAVE_H="$YAVTA_H"

                    MEDIA_CTL_V_LIST="$(
                        printf '%s\n' "$MEDIA_CTL_V_LIST" \
                          | sed -E "s/fmt:[^/]+\//fmt:${ALT_MBUS_A}\//g"
                    )"

                    log_info "Applying format fallback (A1): video $TARGET_FORMAT → $ALT_FMT_A, pads → $ALT_MBUS_A"
                    print_planned_commands "$MEDIA_NODE" "$ALT_FMT_A"
                    configure_pipeline_block "$MEDIA_NODE" "$ALT_FMT_A"
                    camera_rdi_capture_attempt "$FRAMES" "$ALT_FMT_A"
                    RET=$?

                    if [ "$RET" -eq 1 ] && [ -n "$SAVE_W" ] && [ -n "$SAVE_H" ]; then
                        NEW_W=$(((SAVE_W / 2) * 2))
                        NEW_H=$(((SAVE_H / 2) * 2))

                        if [ "$NEW_W" != "$SAVE_W" ] || [ "$NEW_H" != "$SAVE_H" ]; then
                            OLD_SIZE="${SAVE_W}x${SAVE_H}"
                            NEW_SIZE="${NEW_W}x${NEW_H}"

                            MEDIA_CTL_V_LIST="$(camera_rdi_replace_pad_size "$MEDIA_CTL_V_LIST" "$OLD_SIZE" "$NEW_SIZE")"
                            YAVTA_W="$NEW_W"
                            YAVTA_H="$NEW_H"

                            log_info "Applying resolution fallback (A2): ${OLD_SIZE} → ${NEW_SIZE} (format $ALT_FMT_A)"
                            print_planned_commands "$MEDIA_NODE" "$ALT_FMT_A"
                            configure_pipeline_block "$MEDIA_NODE" "$ALT_FMT_A"
                            camera_rdi_capture_attempt "$FRAMES" "$ALT_FMT_A"
                            RET=$?
                        else
                            log_info "Skipping resolution fallback (A2): size already even (${SAVE_W}x${SAVE_H})"
                        fi
                    fi

                    MEDIA_CTL_V_LIST="$SAVE_V"
                    YAVTA_W="$SAVE_W"
                    YAVTA_H="$SAVE_H"
                fi
            fi
            ###################### end #####################################

            ############### Device-supported format fallback ###############
            if [ "$RET" -eq 1 ]; then
                SUP_FMTS="$(v4l2-ctl -d "$YAVTA_DEV" --list-formats 2>/dev/null \
                    | sed -n "s/^[[:space:]]*'\([^']*\)'.*/\1/p")"

                if [ -n "$SUP_FMTS" ]; then
                    ALT_FMT_C=""

                    if printf '%s\n' "$SUP_FMTS" | grep -qx "$TARGET_FORMAT"; then
                        ALT_FMT_C="$TARGET_FORMAT"
                    elif printf '%s\n' "$TARGET_FORMAT" | grep -q 'P$' && \
                         printf '%s\n' "$SUP_FMTS" | grep -qx "$(printf '%s' "$TARGET_FORMAT" | sed 's/P$//')"; then
                        ALT_FMT_C="$(printf '%s' "$TARGET_FORMAT" | sed 's/P$//')"
                    else
                        ALT_FMT_C="$(printf '%s\n' "$SUP_FMTS" | grep -E '^S[RGB]+[0-9]{2}P?$' | head -n 1)"
                        [ -z "$ALT_FMT_C" ] && ALT_FMT_C="$(printf '%s\n' "$SUP_FMTS" | head -n 1)"
                    fi

                    if [ -n "$ALT_FMT_C" ]; then
                        ALT_MBUS_C="$(camera_rdi_video_fmt_to_mbus_fmt "$ALT_FMT_C")"

                        SAVE_V="$MEDIA_CTL_V_LIST"
                        SAVE_W="$YAVTA_W"
                        SAVE_H="$YAVTA_H"

                        MEDIA_CTL_V_LIST="$(
                            printf '%s\n' "$MEDIA_CTL_V_LIST" \
                              | sed -E "s/fmt:[^/]+\//fmt:${ALT_MBUS_C}\//g"
                        )"
                        YAVTA_W=""
                        YAVTA_H=""

                        log_info "Applying device-supported format fallback (C): video $TARGET_FORMAT → $ALT_FMT_C, pads → $ALT_MBUS_C"
                        print_planned_commands "$MEDIA_NODE" "$ALT_FMT_C"
                        configure_pipeline_block "$MEDIA_NODE" "$ALT_FMT_C"
                        camera_rdi_capture_attempt "$FRAMES" "$ALT_FMT_C"
                        RET=$?

                        MEDIA_CTL_V_LIST="$SAVE_V"
                        YAVTA_W="$SAVE_W"
                        YAVTA_H="$SAVE_H"
                    fi
                fi
            fi
            ###################### end #####################################

            RET="$(camera_rdi_final_ret "$RET")"

            case "$RET" in
                0)
                    log_pass "$SENSOR $VIDEO $TARGET_FORMAT PASS"
                    PASS=$((PASS + 1))
                    ;;
                1)
                    log_fail "$SENSOR $VIDEO $TARGET_FORMAT FAIL (capture failed)"
                    FAIL=$((FAIL + 1))
                    ;;
                2)
                    log_skip "$SENSOR $VIDEO $TARGET_FORMAT SKIP (unsupported format)"
                    SKIP=$((SKIP + 1))
                    ;;
                3)
                    log_skip "$SENSOR $VIDEO missing data – skipping"
                    SKIP=$((SKIP + 1))
                    ;;
                *)
                    log_fail "$SENSOR $VIDEO $TARGET_FORMAT FAIL (unknown return: $RET)"
                    FAIL=$((FAIL + 1))
                    ;;
            esac

            camera_rdi_restore_format_iteration
        done

        IFS="$OLD_IFS"
        block=""
    else
        if [ -z "$block" ]; then
            block="$line"
        else
            block="$block
$line"
        fi
    fi

done <"$TMP_PIPELINES_FILE"

if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ] && [ "$SKIP" -eq 0 ]; then
    log_skip "$TESTNAME SKIP – No pipeline blocks were processed"
    log_info "[DEBUG] Parser output file: ${PARSER_OUT_FILE:-unknown}"
    log_info "[DEBUG] Topology file: ${TOPO_FILE:-unknown}"

    if [ -n "${PARSER_OUT_FILE:-}" ] && [ -f "$PARSER_OUT_FILE" ]; then
        log_info "[DEBUG] Parser output:"
        while IFS= read -r line; do
            [ -n "$line" ] && log_info "[PARSER] $line"
        done <"$PARSER_OUT_FILE"
    fi

    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 2
fi

log_info "Test Summary: Passed: $PASS, Failed: $FAIL, Skipped: $SKIP"

if [ "$PASS" -gt 0 ]; then
    echo "$TESTNAME PASS" >"$RES_FILE"
    exit 0
elif [ "$FAIL" -gt 0 ]; then
    echo "$TESTNAME FAIL" >"$RES_FILE"
    exit 1
else
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi
