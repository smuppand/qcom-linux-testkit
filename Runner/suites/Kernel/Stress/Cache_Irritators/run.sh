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

TESTNAME="Cache_Irritators"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"

MODE="nominal"
MODE_SELECTED=0
WORKERS=1
OPERATIONS_OVERRIDE="auto"
STRESS_TIMEOUT_SECONDS=120
CACHE_OPTIONS="auto"
CACHE_SIZE="auto"
CACHE_WAYS="auto"
SHOW_HELP=0

usage() {
    cat <<EOF
Usage: $0 [--nominal | --repeatability | --stress | --mode <mode>] [OPTIONS]

Modes:
  -n, --nominal          Run one operation unit per available workload (default)
  -r, --repeatability    Run ten operation units per available workload
  -s, --stress           Run one hundred operation units per available workload

Options:
  --workers <count>      stress-ng workers per supported stressor (default: 1)
  --operations <count>   Override mode operation units (default: auto)
  --timeout <seconds>    Maximum time per stressor (default: 120)
  --cache-options <csv>  Cache flags: auto, none, enable-all, fence, flush,
                         no-affinity, permute, prefetch (default: auto)
  --cache-size <size>    Override stress-ng cache size, for example 4M
  --cache-ways <count>   Limit the cache ways exercised
  -h, --help             Show this help and exit
EOF
}

# Select exactly one workload mode.
select_mode() {
    requested_mode="$1"

    if [ "$MODE_SELECTED" -eq 1 ]; then
        log_error "Select only one of --nominal, --repeatability, or --stress"
        return 1
    fi

    MODE="$requested_mode"
    MODE_SELECTED=1
}

# Parse and validate command-line arguments.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -n|--nominal)
                select_mode nominal || return 1
                ;;
            -r|--repeatability)
                select_mode repeatability || return 1
                ;;
            -s|--stress)
                select_mode stress || return 1
                ;;
            --mode)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "--mode requires nominal, repeatability, or stress"
                    return 1
                fi
                case "$1" in
                    nominal|repeatability|stress)
                        select_mode "$1" || return 1
                        ;;
                    *)
                        log_error "Unsupported mode: $1"
                        return 1
                        ;;
                esac
                ;;
            --workers)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "--workers requires a positive integer"
                    return 1
                fi
                WORKERS="$1"
                ;;
            --operations)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "--operations requires auto or a positive integer"
                    return 1
                fi
                OPERATIONS_OVERRIDE="$1"
                ;;
            --timeout)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "--timeout requires a positive integer"
                    return 1
                fi
                STRESS_TIMEOUT_SECONDS="$1"
                ;;
            --cache-options)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "--cache-options requires auto, none, or a comma-separated option list"
                    return 1
                fi
                CACHE_OPTIONS="$1"
                ;;
            --cache-size)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "--cache-size requires auto or a byte size such as 4M"
                    return 1
                fi
                CACHE_SIZE="$1"
                ;;
            --cache-ways)
                shift
                if [ "$#" -eq 0 ]; then
                    log_error "--cache-ways requires auto or a positive integer"
                    return 1
                fi
                CACHE_WAYS="$1"
                ;;
            -h|--help)
                SHOW_HELP=1
                ;;
            *)
                log_error "Unknown argument: $1"
                usage >&2
                return 1
                ;;
        esac
        shift
    done

    case "$WORKERS" in
        ''|*[!0-9]*|0)
            log_error "--workers must be a positive integer: $WORKERS"
            return 1
            ;;
    esac

    case "$STRESS_TIMEOUT_SECONDS" in
        ''|*[!0-9]*|0)
            log_error "--timeout must be a positive integer: $STRESS_TIMEOUT_SECONDS"
            return 1
            ;;
    esac

    case "$OPERATIONS_OVERRIDE" in
        auto)
            ;;
        ''|*[!0-9]*|0)
            log_error "--operations must be auto or a positive integer: $OPERATIONS_OVERRIDE"
            return 1
            ;;
    esac

    case "$CACHE_WAYS" in
        auto)
            ;;
        ''|*[!0-9]*|0)
            log_error "--cache-ways must be auto or a positive integer: $CACHE_WAYS"
            return 1
            ;;
    esac

    if [ "$CACHE_SIZE" != "auto" ] &&
       ! printf '%s\n' "$CACHE_SIZE" |
           grep -Eq '^[1-9][0-9]*([bBkKmMgGtTpPeE]([bB])?)?$'; then
        log_error "--cache-size must be auto or a positive byte size such as 4M: $CACHE_SIZE"
        return 1
    fi

    if [ -z "$CACHE_OPTIONS" ]; then
        log_error "--cache-options must not be empty"
        return 1
    fi
}

# Report whether the installed stress-ng help advertises an exact option.
stress_ng_has_option() {
    option_name="$1"

    grep -Eq -- "(^|[[:space:]])${option_name}([[:space:]]|=)" \
        "$STRESS_NG_HELP_LOG"
}

# Print the unique L1, L2, and L3 cache levels exposed by CPU sysfs.
discover_cache_levels() {
    discovered_levels=""

    for level_file in /sys/devices/system/cpu/cpu[0-9]*/cache/index*/level; do
        [ -r "$level_file" ] || continue
        IFS= read -r cache_level <"$level_file" || continue

        case "$cache_level" in
            1|2|3)
                case " $discovered_levels " in
                    *" $cache_level "*)
                        ;;
                    *)
                        discovered_levels="${discovered_levels}${discovered_levels:+ }$cache_level"
                        ;;
                esac
                ;;
        esac
    done

    printf '%s\n' "$discovered_levels"
}

# Run one supported stressor with operation and watchdog limits.
run_stressor() {
    stressor_name="$1"
    cache_level="${2:-all}"
    watchdog_seconds=$((STRESS_TIMEOUT_SECONDS + 10))

    case "$stressor_name" in
        cache)
            if [ "$cache_level" = "all" ]; then
                stressor_label="cache-all"
            else
                stressor_label="cache-level-$cache_level"
            fi
            set -- stress-ng \
                --cache "$WORKERS" \
                --cache-ops "$OPERATIONS"
            if [ "$cache_level" != "all" ]; then
                set -- "$@" --cache-level "$cache_level"
            fi
            for cache_option in $CACHE_OPTIONS_EFFECTIVE; do
                set -- "$@" "--cache-$cache_option"
            done
            if [ "$CACHE_SIZE" != "auto" ]; then
                set -- "$@" --cache-size "$CACHE_SIZE"
            fi
            if [ "$CACHE_WAYS" != "auto" ]; then
                set -- "$@" --cache-ways "$CACHE_WAYS"
            fi
            ;;
        tlb-shootdown)
            stressor_label="tlb-shootdown"
            set -- stress-ng \
                --tlb-shootdown "$WORKERS" \
                --tlb-shootdown-ops "$OPERATIONS"
            ;;
        *)
            test_result_record "FAIL" \
                "Unknown cache irritator stressor requested: $stressor_name"
            return 1
            ;;
    esac
    stressor_log="$RESULT_DIR/${stressor_label}.log"

    if stress_ng_has_option --verify; then
        set -- "$@" --verify
    fi
    if stress_ng_has_option --metrics-brief; then
        set -- "$@" --metrics-brief
    fi
    if stress_ng_has_option --timeout; then
        set -- "$@" --timeout "${STRESS_TIMEOUT_SECONDS}s"
    fi

    log_info "[CACHE-IRRITATOR] stressor=$stressor_label mode=$MODE workers=$WORKERS operations=$OPERATIONS watchdog=${watchdog_seconds}s"
    log_info "Executing: $*"

    run_with_managed_timeout \
        "$watchdog_seconds" \
        "$RESULT_DIR" \
        "cache-irritators-${stressor_label}" \
        "$@" >"$stressor_log" 2>&1
    stressor_rc=$?

    log_file_with_label "STRESS-NG-$stressor_label" "$stressor_log" 80

    if [ "$stressor_rc" -ne 0 ]; then
        test_result_record "FAIL" \
            "$stressor_label stress failed, rc=$stressor_rc mode=$MODE artifact=$stressor_log"
        return 1
    fi

    if grep -Eiq \
        'failed:[[:space:]]*[1-9]|skipped:[[:space:]]*[1-9]|unsuccessful|not implemented|not available' \
        "$stressor_log"; then
        test_result_record "FAIL" \
            "$stressor_label stress reported an incomplete or failed workload, mode=$MODE artifact=$stressor_log"
        return 1
    fi

    test_result_record "PASS" \
        "$stressor_label stress completed, mode=$MODE workers=$WORKERS operations=$OPERATIONS artifact=$stressor_log"
    return 0
}

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

if ! parse_args "$@"; then
    test_result_record "FAIL" "Invalid Cache_Irritators command-line arguments"
    test_result_finish
fi

if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
fi

case "$MODE" in
    nominal)
        OPERATIONS=1
        ;;
    repeatability)
        OPERATIONS=10
        ;;
    stress)
        OPERATIONS=100
        ;;
esac
if [ "$OPERATIONS_OVERRIDE" != "auto" ]; then
    OPERATIONS="$OPERATIONS_OVERRIDE"
fi

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"
log_info "Mode: $MODE"
log_info "Requested cache options: $CACHE_OPTIONS"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies grep tr date mkdir; then
    test_result_finish "SKIP" \
        "$TESTNAME SKIP: required base utilities are unavailable"
fi

OS_ID=$(pkg_detect_os_id 2>/dev/null || printf '%s\n' unknown)
case "$OS_ID" in
    debian|ubuntu|centos)
        pkg_ensure_host_distro_package_set_present cache-irritators
        package_status=$?
        case "$package_status" in
            0)
                log_info "Cache irritators package set is ready, os=$OS_ID"
                ;;
            1)
                test_result_finish "FAIL" \
                    "$TESTNAME FAIL: unable to install the stress-ng package and dependencies on $OS_ID"
                ;;
            2)
                test_result_finish "FAIL" \
                    "$TESTNAME FAIL: cache-irritators package mapping is unavailable for $OS_ID"
                ;;
            *)
                test_result_finish "FAIL" \
                    "$TESTNAME FAIL: package preparation returned unexpected status $package_status for $OS_ID"
                ;;
        esac
        ;;
    *)
        log_info "Package recovery is not enabled for image-managed or unsupported OS, os=$OS_ID"
        ;;
esac

if ! command -v stress-ng >/dev/null 2>&1; then
    test_result_finish "SKIP" \
        "$TESTNAME SKIP: stress-ng is unavailable on os=$OS_ID, include stress-ng in the target image or use Debian, Ubuntu, or CentOS package recovery"
fi

RESULT_DIR="$SCRIPT_DIR/logs_${TESTNAME}_$(date -u +%Y%m%d-%H%M%S)"
if ! mkdir -p "$RESULT_DIR"; then
    test_result_finish "FAIL" \
        "$TESTNAME FAIL: unable to create artifact directory $RESULT_DIR"
fi

STRESS_NG_HELP_LOG="$RESULT_DIR/stress-ng-help.log"
STRESS_NG_VERSION_LOG="$RESULT_DIR/stress-ng-version.log"

stress-ng --version >"$STRESS_NG_VERSION_LOG" 2>&1 || true
log_file_with_label "STRESS-NG-VERSION" "$STRESS_NG_VERSION_LOG" 10

if ! stress-ng --help >"$STRESS_NG_HELP_LOG" 2>&1; then
    test_result_finish "FAIL" \
        "$TESTNAME FAIL: installed stress-ng could not report capabilities, artifact=$STRESS_NG_HELP_LOG"
fi

if ! stress_ng_has_option --cache ||
   ! stress_ng_has_option --cache-ops; then
    test_result_finish "SKIP" \
        "$TESTNAME SKIP: installed stress-ng does not advertise --cache and --cache-ops, provide an image with the cache stressor, artifact=$STRESS_NG_HELP_LOG"
fi

case "$CACHE_OPTIONS" in
    auto)
        if stress_ng_has_option --cache-enable-all; then
            CACHE_OPTIONS_EFFECTIVE="enable-all"
        else
            CACHE_OPTIONS_EFFECTIVE=""
            log_info "Automatic cache tuning found no --cache-enable-all capability"
        fi
        ;;
    none)
        CACHE_OPTIONS_EFFECTIVE=""
        ;;
    *)
        CACHE_OPTIONS_EFFECTIVE=$(printf '%s\n' "$CACHE_OPTIONS" | tr ',' ' ')
        for cache_option in $CACHE_OPTIONS_EFFECTIVE; do
            case "$cache_option" in
                enable-all|fence|flush|no-affinity|permute|prefetch)
                    ;;
                *)
                    test_result_finish "FAIL" \
                        "$TESTNAME FAIL: unsupported --cache-options value '$cache_option'"
                    ;;
            esac

            if ! stress_ng_has_option "--cache-$cache_option"; then
                test_result_finish "FAIL" \
                    "$TESTNAME FAIL: explicitly requested stress-ng option --cache-$cache_option is not advertised by the installed binary, artifact=$STRESS_NG_HELP_LOG"
            fi
        done
        ;;
esac

if [ "$CACHE_SIZE" != "auto" ] &&
   ! stress_ng_has_option --cache-size; then
    test_result_finish "FAIL" \
        "$TESTNAME FAIL: --cache-size was requested but is not advertised by the installed stress-ng, artifact=$STRESS_NG_HELP_LOG"
fi

if [ "$CACHE_WAYS" != "auto" ] &&
   ! stress_ng_has_option --cache-ways; then
    test_result_finish "FAIL" \
        "$TESTNAME FAIL: --cache-ways was requested but is not advertised by the installed stress-ng, artifact=$STRESS_NG_HELP_LOG"
fi

log_info "Effective cache options: ${CACHE_OPTIONS_EFFECTIVE:-none}"
log_info "Cache size override: $CACHE_SIZE"
log_info "Cache ways override: $CACHE_WAYS"

run_stressor cache all || true

if stress_ng_has_option --cache-level; then
    CACHE_LEVELS=$(discover_cache_levels)
    if [ -n "$CACHE_LEVELS" ]; then
        log_info "Runtime-discovered cache levels: $CACHE_LEVELS"
        for cache_level in $CACHE_LEVELS; do
            run_stressor cache "$cache_level" || true
        done
    else
        test_result_record "SKIP" \
            "Per-level cache stress is unavailable because CPU cache levels were not exposed in sysfs"
    fi
else
    test_result_record "SKIP" \
        "Per-level cache stress is unavailable because installed stress-ng does not advertise --cache-level, artifact=$STRESS_NG_HELP_LOG"
fi

if stress_ng_has_option --tlb-shootdown &&
   stress_ng_has_option --tlb-shootdown-ops; then
    run_stressor tlb-shootdown || true
else
    test_result_record "SKIP" \
        "TLB shootdown stress is unavailable because installed stress-ng does not advertise --tlb-shootdown and --tlb-shootdown-ops, artifact=$STRESS_NG_HELP_LOG"
fi

if scan_dmesg_errors \
    "$RESULT_DIR" \
    'cache|tlb|memory management|BUG:|Oops|panic|soft lockup|hard lockup|hung task' \
    'cache hierarchy|cacheinfo|Detected.*cache|TLB entries'; then
    test_result_record "FAIL" \
        "Kernel errors relevant to cache or TLB stress were found, artifact=$RESULT_DIR/dmesg_errors.log"
elif [ "${DMESG_ACCESS_STATUS:-unavailable}" != "available" ]; then
    test_result_record "SKIP" \
        "Kernel log access is unavailable for cache/TLB health validation, status=${DMESG_ACCESS_STATUS:-unknown} provider=${DMESG_ACCESS_PROVIDER:-none} rc=${DMESG_ACCESS_RC:-unknown} artifact=$RESULT_DIR/dmesg_access.log"
else
    test_result_record "PASS" \
        "No relevant cache or TLB errors were found in the captured kernel log"
fi

test_result_finish
