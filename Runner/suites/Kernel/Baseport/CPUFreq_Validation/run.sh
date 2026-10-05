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

TESTNAME="CPUFreq_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

CPUFREQ_ROOT="/sys/devices/system/cpu/cpufreq"
TOLERANCE_KHZ=400
SETTLE_ATTEMPTS=5
PARSE_ERROR=""
RESTORE_DONE=0

usage() {
    cat <<'EOF'
Usage: ./run.sh [OPTIONS]

Validate CPUFreq policy topology, advertised OPP frequencies, and functional
frequency transitions while restoring every modified policy.

Options:
  --tolerance-khz <khz>  Maximum readback difference, 0-1000000 (default: 400)
  --settle-attempts <n>  One-second readback attempts, 1-30 (default: 5)
  -h, --help             Show help and exit
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tolerance-khz)
                if [ "$#" -lt 2 ]; then
                    PARSE_ERROR="--tolerance-khz requires a value"
                    return 1
                fi
                TOLERANCE_KHZ="$2"
                shift 2
                ;;
            --settle-attempts)
                if [ "$#" -lt 2 ]; then
                    PARSE_ERROR="--settle-attempts requires a value"
                    return 1
                fi
                SETTLE_ATTEMPTS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                PARSE_ERROR="unknown option: $1"
                return 1
                ;;
        esac
    done

    if ! is_unsigned_number "$TOLERANCE_KHZ" ||
       [ "$TOLERANCE_KHZ" -gt 1000000 ]; then
        PARSE_ERROR="--tolerance-khz must be an integer from 0 through 1000000"
        return 1
    fi

    if ! is_unsigned_number "$SETTLE_ATTEMPTS" ||
       [ "$SETTLE_ATTEMPTS" -lt 1 ] || [ "$SETTLE_ATTEMPTS" -gt 30 ]; then
        PARSE_ERROR="--settle-attempts must be an integer from 1 through 30"
        return 1
    fi

    return 0
}

restore_cpufreq_state() {
    rcs_failed=0

    if [ "$RESTORE_DONE" -eq 1 ]; then
        return 0
    fi
    RESTORE_DONE=1

    if [ -n "${SNAPSHOT_FILE:-}" ] && [ -r "$SNAPSHOT_FILE" ]; then
        cpufreq_policy_restore "$SNAPSHOT_FILE" || rcs_failed=1
    fi

    debugfs_restore || rcs_failed=1
    return "$rcs_failed"
}

handle_signal() {
    cfh_signal="$1"
    trap - 0 1 2 15

    if ! restore_cpufreq_state; then
        test_result_record \
            "FAIL" \
            "CPUFreq policy state could not be restored after $cfh_signal"
    fi

    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: interrupted by $cfh_signal after restoring CPUFreq policy state"
}

cd "$SCRIPT_DIR" || exit 1
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! parse_args "$@"; then
    usage >&2
    test_result_finish "FAIL" "$TESTNAME FAIL: invalid command line, $PARSE_ERROR"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME testcase"
log_info "Kernel: $(uname -a 2>/dev/null || printf 'unknown')"
log_info "[CPUFREQ-OP] mode=all-advertised-frequencies tolerance_khz=$TOLERANCE_KHZ settle_attempts=$SETTLE_ATTEMPTS"

RESULT_DIR="$SCRIPT_DIR/logs_${TESTNAME}_$(date -u +%Y%m%d-%H%M%S)"
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: cannot create evidence directory $RESULT_DIR"
fi
log_info "Evidence directory: $RESULT_DIR"

# shellcheck disable=SC2034  # Consumed by the sourced dependency helper.
CHECK_DEPS_RECOVER=0
# shellcheck disable=SC2034  # Consumed by the sourced dependency helper.
CHECK_DEPS_NO_EXIT=1
if ! check_dependencies \
    awk \
    basename \
    cat \
    date \
    dirname \
    mkdir \
    readlink \
    rm \
    sleep \
    sort \
    tr \
    uname \
    wc; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: required image-provided base utilities are unavailable"
fi

POLICY_COUNT=0
for POLICY_DIR in "$CPUFREQ_ROOT"/policy*; do
    [ -d "$POLICY_DIR" ] || continue
    POLICY_COUNT=$((POLICY_COUNT + 1))
done

if [ "$POLICY_COUNT" -eq 0 ]; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: no CPUFreq policy directories are exposed under $CPUFREQ_ROOT, enable the platform CPUFreq driver"
fi

SNAPSHOT_FILE="$RESULT_DIR/cpufreq_policy_snapshot.log"
if ! cpufreq_policy_snapshot "$CPUFREQ_ROOT" "$SNAPSHOT_FILE"; then
    test_result_finish \
        "FAIL" \
        "$TESTNAME FAIL: $POLICY_COUNT CPUFreq policies were detected but their mutable state could not be captured"
fi

CPUFREQ_OPP_ROOT=""
log_info "[CPUFREQ-OP] operation=discover-opp-debugfs"
if debugfs_prepare; then
    if [ -d "$FTEST_DEBUGFS_MOUNTPOINT/opp" ]; then
        CPUFREQ_OPP_ROOT="$FTEST_DEBUGFS_MOUNTPOINT/opp"
        log_info "CPU OPP debugfs root: $CPUFREQ_OPP_ROOT"
    else
        log_info "Optional OPP debugfs directory is not exposed under $FTEST_DEBUGFS_MOUNTPOINT"
    fi
else
    log_info "Optional debugfs OPP diagnostics are unavailable"
fi

trap 'restore_cpufreq_state >/dev/null 2>&1 || true' 0
trap 'handle_signal SIGHUP' 1
trap 'handle_signal SIGINT' 2
trap 'handle_signal SIGTERM' 15

INVENTORY_FILE="$RESULT_DIR/cpufreq_policy_inventory.log"
POINTS_FILE="$RESULT_DIR/cpufreq_frequency_results.csv"
: >"$INVENTORY_FILE"
printf 'policy,related_cpus,target_khz,readback_source,actual_khz,status\n' \
    >"$POINTS_FILE"

TESTED_POLICY_COUNT=0
TESTED_FREQUENCY_COUNT=0

for POLICY_DIR in "$CPUFREQ_ROOT"/policy*; do
    [ -d "$POLICY_DIR" ] || continue
    POLICY=$(basename "$POLICY_DIR")
    RELATED_CPUS=$(awk 'NR == 1 { print; exit }' "$POLICY_DIR/related_cpus" 2>/dev/null || true)
    if [ -z "$RELATED_CPUS" ]; then
        RELATED_CPUS=$(awk 'NR == 1 { print; exit }' "$POLICY_DIR/affected_cpus" 2>/dev/null || true)
    fi
    DRIVER=$(awk 'NR == 1 { print; exit }' "$POLICY_DIR/scaling_driver" 2>/dev/null || true)
    GOVERNOR=$(awk 'NR == 1 { print; exit }' "$POLICY_DIR/scaling_governor" 2>/dev/null || true)
    CPUINFO_MIN=$(awk 'NR == 1 { print; exit }' "$POLICY_DIR/cpuinfo_min_freq" 2>/dev/null || true)
    CPUINFO_MAX=$(awk 'NR == 1 { print; exit }' "$POLICY_DIR/cpuinfo_max_freq" 2>/dev/null || true)

    printf '%s|%s|%s|%s|%s|%s\n' \
        "$POLICY" \
        "${RELATED_CPUS:--}" \
        "${DRIVER:--}" \
        "${GOVERNOR:--}" \
        "${CPUINFO_MIN:--}" \
        "${CPUINFO_MAX:--}" >>"$INVENTORY_FILE"
    log_info "[CPUFREQ-POLICY] policy=$POLICY cpus=${RELATED_CPUS:--} driver=${DRIVER:--} governor=${GOVERNOR:--} min_khz=${CPUINFO_MIN:--} max_khz=${CPUINFO_MAX:--}"

    if [ -z "$RELATED_CPUS" ]; then
        test_result_record \
            "FAIL" \
            "$POLICY has no related_cpus or affected_cpus topology data"
        continue
    fi

    POLICY_TOPOLOGY_OK=1
    for CPU in $RELATED_CPUS; do
        case "$CPU" in
            ''|*[!0-9]*)
                POLICY_TOPOLOGY_OK=0
                continue
                ;;
        esac

        CPU_POLICY_LINK="/sys/devices/system/cpu/cpu$CPU/cpufreq"
        if [ ! -e "$CPU_POLICY_LINK" ]; then
            CPU_ONLINE=$(awk 'NR == 1 { print; exit }' \
                "/sys/devices/system/cpu/cpu$CPU/online" 2>/dev/null || true)
            if [ "$CPU_ONLINE" = "0" ]; then
                continue
            fi
            POLICY_TOPOLOGY_OK=0
            continue
        fi
        RESOLVED_CPU_POLICY=$(readlink -f "$CPU_POLICY_LINK" 2>/dev/null || true)
        RESOLVED_POLICY=$(readlink -f "$POLICY_DIR" 2>/dev/null || true)
        if [ "$RESOLVED_CPU_POLICY" != "$RESOLVED_POLICY" ]; then
            POLICY_TOPOLOGY_OK=0
        fi
    done

    if [ "$POLICY_TOPOLOGY_OK" -eq 1 ]; then
        test_result_record \
            "PASS" \
            "$POLICY topology maps all online related CPUs [$RELATED_CPUS] to the same policy"
    else
        test_result_record \
            "FAIL" \
            "$POLICY topology does not consistently map online related CPUs [$RELATED_CPUS] through per-CPU CPUFreq links"
        continue
    fi

    FREQUENCY_FILE="$RESULT_DIR/${POLICY}_frequencies.log"
    {
        cat "$POLICY_DIR/scaling_available_frequencies" 2>/dev/null || true
        cat "$POLICY_DIR/scaling_boost_frequencies" 2>/dev/null || true
    } | tr ' ' '\n' | awk '/^[0-9]+$/ && $1 > 0 { print $1 }' | sort -nu \
        >"$FREQUENCY_FILE"

    if [ ! -s "$FREQUENCY_FILE" ]; then
        {
            printf '%s\n' "$CPUINFO_MIN"
            printf '%s\n' "$CPUINFO_MAX"
        } | awk '/^[0-9]+$/ && $1 > 0 { print $1 }' | sort -nu \
            >"$FREQUENCY_FILE"
        test_result_record \
            "SKIP" \
            "$POLICY does not expose scaling_available_frequencies, functional coverage is limited to its advertised cpuinfo endpoints"
    else
        test_result_record \
            "PASS" \
            "$POLICY exposes a discrete CPUFreq OPP frequency table"
    fi

    FREQUENCY_COUNT=$(wc -l <"$FREQUENCY_FILE" | tr -d '[:space:]')
    if [ "$FREQUENCY_COUNT" -eq 0 ]; then
        test_result_record \
            "FAIL" \
            "$POLICY exposes neither a discrete frequency table nor valid cpuinfo frequency endpoints"
        continue
    fi

    FIRST_FREQUENCY=$(awk 'NR == 1 { print; exit }' "$FREQUENCY_FILE")
    LAST_FREQUENCY=$(awk 'END { print }' "$FREQUENCY_FILE")
    case "$CPUINFO_MIN:$CPUINFO_MAX" in
        *[!0-9:]*|:*|*:)
            test_result_record \
                "FAIL" \
                "$POLICY cpuinfo_min_freq or cpuinfo_max_freq is missing or malformed"
            continue
            ;;
    esac

    if [ "$FIRST_FREQUENCY" -lt "$CPUINFO_MIN" ] ||
       [ "$LAST_FREQUENCY" -gt "$CPUINFO_MAX" ]; then
        test_result_record \
            "FAIL" \
            "$POLICY frequency table range ${FIRST_FREQUENCY}-${LAST_FREQUENCY} kHz exceeds cpuinfo range ${CPUINFO_MIN}-${CPUINFO_MAX} kHz"
        continue
    fi

    test_result_record \
        "PASS" \
        "$POLICY frequency table contains $FREQUENCY_COUNT valid entries within ${CPUINFO_MIN}-${CPUINFO_MAX} kHz"

    OPP_DEVICE_DIR=""
    if [ -n "$CPUFREQ_OPP_ROOT" ]; then
        for CPU in $RELATED_CPUS; do
            for OPP_CANDIDATE in \
                "$CPUFREQ_OPP_ROOT/cpu$CPU" \
                "$CPUFREQ_OPP_ROOT"/*-cpu"$CPU"; do
                if [ -d "$OPP_CANDIDATE" ]; then
                    OPP_DEVICE_DIR="$OPP_CANDIDATE"
                    break
                fi
            done
            [ -n "$OPP_DEVICE_DIR" ] && break
        done
    fi

    if [ -n "$OPP_DEVICE_DIR" ]; then
        OPP_FREQUENCY_FILE="$RESULT_DIR/${POLICY}_opp_frequencies.log"
        OPP_MISMATCH_FILE="$RESULT_DIR/${POLICY}_opp_mismatches.log"
        log_info "[CPUFREQ-OP] operation=compare-policy-opp policy=$POLICY source=$OPP_DEVICE_DIR"

        if cpufreq_opp_frequencies_khz \
            "$OPP_DEVICE_DIR" \
            "$OPP_FREQUENCY_FILE"; then
            awk '
                NR == FNR {
                    policy[$1] = 1
                    next
                }
                {
                    opp[$1] = 1
                }
                END {
                    for (frequency in policy) {
                        if (!(frequency in opp)) {
                            print "missing_from_opp|" frequency
                        }
                    }
                    for (frequency in opp) {
                        if (!(frequency in policy)) {
                            print "missing_from_cpufreq|" frequency
                        }
                    }
                }
            ' "$FREQUENCY_FILE" "$OPP_FREQUENCY_FILE" \
                >"$OPP_MISMATCH_FILE"

            if [ -s "$OPP_MISMATCH_FILE" ]; then
                test_result_record \
                    "FAIL" \
                    "$POLICY CPUFreq frequency table does not match its available OPP debugfs rates, artifact=$OPP_MISMATCH_FILE"
                log_file_with_label \
                    "CPUFREQ-OPP-MISMATCH:$POLICY" \
                    "$OPP_MISMATCH_FILE" \
                    0
            else
                rm -f "$OPP_MISMATCH_FILE"
                test_result_record \
                    "PASS" \
                    "$POLICY CPUFreq table matches all available OPP debugfs rates"
            fi
        else
            test_result_record \
                "FAIL" \
                "$POLICY OPP debugfs directory is present but exposes no readable available rate entries, source=$OPP_DEVICE_DIR"
        fi
    else
        test_result_record \
            "SKIP" \
            "$POLICY has no matching CPU OPP debugfs directory, policy sysfs remains the authoritative frequency table"
    fi

    if [ ! -w "$POLICY_DIR/scaling_min_freq" ] ||
       [ ! -w "$POLICY_DIR/scaling_max_freq" ]; then
        test_result_record \
            "SKIP" \
            "$POLICY functional scaling cannot run because scaling_min_freq or scaling_max_freq is not writable, run as root on an image permitting CPUFreq policy changes"
        continue
    fi

    TESTED_POLICY_COUNT=$((TESTED_POLICY_COUNT + 1))
    POLICY_FAILED=0
    log_info "[CPUFREQ-OP] operation=sweep-policy policy=$POLICY frequencies=$FREQUENCY_COUNT"

    while IFS= read -r FREQUENCY; do
        [ -n "$FREQUENCY" ] || continue
        TESTED_FREQUENCY_COUNT=$((TESTED_FREQUENCY_COUNT + 1))
        log_info "[CPUFREQ-OP] operation=set-frequency policy=$POLICY target_khz=$FREQUENCY"

        if ! cpufreq_policy_set_frequency "$POLICY_DIR" "$FREQUENCY"; then
            printf '%s,%s,%s,-,-,FAIL\n' \
                "$POLICY" "$RELATED_CPUS" "$FREQUENCY" >>"$POINTS_FILE"
            test_result_record \
                "FAIL" \
                "$POLICY rejected advertised frequency $FREQUENCY kHz"
            POLICY_FAILED=1
            continue
        fi

        if READBACK=$(cpufreq_policy_wait_for_frequency \
            "$POLICY_DIR" \
            "$FREQUENCY" \
            "$TOLERANCE_KHZ" \
            "$SETTLE_ATTEMPTS"); then
            READBACK_SOURCE=${READBACK%%=*}
            ACTUAL_FREQUENCY=${READBACK#*=}
            printf '%s,%s,%s,%s,%s,PASS\n' \
                "$POLICY" \
                "$RELATED_CPUS" \
                "$FREQUENCY" \
                "$READBACK_SOURCE" \
                "$ACTUAL_FREQUENCY" >>"$POINTS_FILE"
            log_info "[CPUFREQ-POINT] policy=$POLICY target_khz=$FREQUENCY $READBACK status=PASS"
        else
            ACTUAL_FREQUENCY=$(awk 'NR == 1 { print; exit }' "$POLICY_DIR/scaling_cur_freq" 2>/dev/null || true)
            printf '%s,%s,%s,scaling_cur_freq,%s,FAIL\n' \
                "$POLICY" \
                "$RELATED_CPUS" \
                "$FREQUENCY" \
                "${ACTUAL_FREQUENCY:--}" >>"$POINTS_FILE"
            test_result_record \
                "FAIL" \
                "$POLICY did not reach advertised frequency $FREQUENCY kHz within $SETTLE_ATTEMPTS second(s), tolerance=${TOLERANCE_KHZ}kHz actual=${ACTUAL_FREQUENCY:-unavailable}kHz"
            POLICY_FAILED=1
        fi
    done <"$FREQUENCY_FILE"

    if ! cpufreq_policy_restore "$SNAPSHOT_FILE"; then
        test_result_record \
            "FAIL" \
            "$POLICY sweep completed but original CPUFreq limits or governor could not be restored"
        POLICY_FAILED=1
    fi

    if [ "$POLICY_FAILED" -eq 0 ]; then
        test_result_record \
            "PASS" \
            "$POLICY reached all $FREQUENCY_COUNT advertised frequency point(s) and its original state was restored"
    fi
done

log_file_with_label "CPUFREQ-INVENTORY" "$INVENTORY_FILE" 0

if [ "$TESTED_POLICY_COUNT" -eq 0 ]; then
    test_result_record \
        "SKIP" \
        "No detected CPUFreq policy permitted functional frequency transitions"
elif [ "$TESTED_POLICY_COUNT" -lt "$POLICY_COUNT" ]; then
    test_result_record \
        "SKIP" \
        "Functional transitions ran on $TESTED_POLICY_COUNT of $POLICY_COUNT CPUFreq policies"
else
    test_result_record \
        "PASS" \
        "Executed functional CPUFreq transitions across $TESTED_POLICY_COUNT policy or policies and $TESTED_FREQUENCY_COUNT frequency point(s)"
fi

log_info "[CPUFREQ-OP] operation=scan-kernel-log modules=cpufreq,qcom-cpufreq-hw,opp"
if scan_dmesg_errors \
    "$RESULT_DIR" \
    'cpufreq|qcom.*cpufreq|qcom-cpufreq-hw|operating performance point|opp'; then
    test_result_record \
        "FAIL" \
        "CPUFreq or OPP kernel errors were found in $RESULT_DIR/dmesg_errors.log"
elif [ "${DMESG_ACCESS_STATUS:-unknown}" = "unavailable" ]; then
    test_result_record \
        "SKIP" \
        "Kernel log access is unavailable for CPUFreq driver health validation"
else
    test_result_record \
        "PASS" \
        "No non-benign CPUFreq or OPP errors were found in the captured kernel log"
fi

if ! restore_cpufreq_state; then
    test_result_record \
        "FAIL" \
        "Original CPUFreq policy state could not be restored during final cleanup"
fi
trap - 0 1 2 15

log_info "[CPUFREQ-RESULT] policies=$POLICY_COUNT tested_policies=$TESTED_POLICY_COUNT tested_frequencies=$TESTED_FREQUENCY_COUNT"
if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ]; then
    test_result_finish "FAIL"
elif [ "$TESTED_POLICY_COUNT" -lt "$POLICY_COUNT" ]; then
    test_result_finish \
        "SKIP" \
        "$TESTNAME SKIP: functional transitions completed on $TESTED_POLICY_COUNT of $POLICY_COUNT detected policies"
else
    test_result_finish "PASS"
fi
