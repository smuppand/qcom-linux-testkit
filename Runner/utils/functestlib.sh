#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Resolve the directory of this script
UTILS_DIR=$(CDPATH=cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd)

# Safely source init_env if present
if [ -f "$UTILS_DIR/init_env" ]; then
    # shellcheck disable=SC1090
    . "$UTILS_DIR/init_env"
fi

# Import platform script if available
if [ -f "${TOOLS}/platform.sh" ]; then
    # shellcheck disable=SC1090
    . "${TOOLS}/platform.sh"
fi

# Fallbacks (only if init_env didn't set them)
__RUNNER_SUITES_DIR="${__RUNNER_SUITES_DIR:-${ROOT_DIR}/suites}"
#__RUNNER_UTILS_BIN_DIR="${__RUNNER_UTILS_BIN_DIR:-${ROOT_DIR}/common}"

# Logging
log() {
    local level="$1"
    shift
    echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a /var/test_output.log
}
log_info() { log "INFO" "$@" >&2; }
log_pass() { log "PASS" "$@" >&2; }
log_fail() { log "FAIL" "$@" >&2; }
log_error() { log "ERROR" "$@" >&2; }

# Dependency check
check_dependencies() {
    local missing=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "ERROR: Required command '$cmd' not found in PATH."
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        log_error "Exiting due to missing dependencies."
        exit 1
    else
        log_pass "Test related dependencies are present."
    fi
}

# Auto-detect suites dir if not already set
auto_detect_suites_dir() {
    if [ -z "$__RUNNER_SUITES_DIR" ]; then
        local base=$(pwd)
        while [ "$base" != "/" ]; do
            if [ -d "$base/suites" ]; then
                __RUNNER_SUITES_DIR="$base/suites"
                break
            fi
            parent=$(dirname "$base")
            [ "$parent" = "$base" ] && break
            base="$parent"
        done
    fi
}

# Auto-detect utils/common dir if not set
auto_detect_utils_dir() {
    if [ -z "$__RUNNER_UTILS_BIN_DIR" ]; then
        local base=$(pwd)
        while [ "$base" != "/" ]; do
            if [ -d "$base/common" ]; then
                __RUNNER_UTILS_BIN_DIR="$base/common"
                break
            fi
            parent=$(dirname "$base")
            [ "$parent" = "$base" ] && break
            base="$parent"
        done
    fi
}

# POSIX-safe test case directory lookup
find_test_case_by_name() {
    local test_name="$1"
    auto_detect_suites_dir

    if [ -z "$__RUNNER_SUITES_DIR" ]; then
        log_error "__RUNNER_SUITES_DIR not set or could not be detected"
        return 1
    fi

    log_info "Searching for test '$test_name' in $__RUNNER_SUITES_DIR"
    local testpath
    testpath=$(find "$__RUNNER_SUITES_DIR" -type d -iname "$test_name" -print -quit 2>/dev/null)

    if [ -z "$testpath" ]; then
        log_error "Test '$test_name' not found"
        return 1
    fi

    log_info "Resolved test path for '$test_name': $testpath"
    echo "$testpath"
}

find_test_case_bin_by_name() {
    local test_name="$1"
    auto_detect_utils_dir

    if [ -z "$__RUNNER_UTILS_BIN_DIR" ]; then
        log_error "__RUNNER_UTILS_BIN_DIR not set or could not be detected"
        return 1
    fi

    find "$__RUNNER_UTILS_BIN_DIR" -type f -iname "$test_name" -print -quit 2>/dev/null
}

find_test_case_script_by_name() {
    local test_name="$1"
    auto_detect_utils_dir

    if [ -z "$__RUNNER_UTILS_BIN_DIR" ]; then
        log_error "__RUNNER_UTILS_BIN_DIR not set or could not be detected"
        return 1
    fi

    find "$__RUNNER_UTILS_BIN_DIR" -type d -iname "$test_name" -print -quit 2>/dev/null
}

# POSIX-safe repo root detector (used by run.sh scripts)
detect_runner_root() {
    local path="$1"
    while [ "$path" != "/" ]; do
        if [ -d "$path/suites" ]; then
            echo "$path"
            return
        fi
        path=$(dirname "$path")
    done
    echo ""
}

# Optional self-doc generator
FUNCTIONS="\
log_info \
log_pass \
log_fail \
log_error \
find_test_case_by_name \
find_test_case_bin_by_name \
find_test_case_script_by_name \
log \
detect_runner_root \
"

functestlibdoc() {
    echo "functestlib.sh"
    echo ""
    echo "Functions:"
    for fn in $FUNCTIONS; do
        echo "$fn"
        eval "$fn""_doc"
        echo ""
    done
    echo "Note: These functions may not behave as expected on systems with >=32 CPUs"
}
