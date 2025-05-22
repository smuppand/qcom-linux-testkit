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
log_skip() { log "SKIP" "$@"; >&2; }

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
}

# ----------------------------
# Additional Utility Functions
# ----------------------------

check_network_status() {
    log_info "Checking network connectivity..."

    ip_addr=$(ip -4 addr show scope global up | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}' | head -n 1)

    if [ -n "$ip_addr" ]; then
        log_pass "Network is active. IP address: $ip_addr"
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            log_pass "Internet is reachable."
            return 0
        else
            log_error "Network active but no internet access."
            return 2
        fi
    else
        log_fail "No active network interface found."
        return 1
    fi
}

check_tar_file() {
    local url="$1"
    local filename
    local foldername

    filename=$(basename "$url")
    foldername="${filename%.tar*}" # assumes .tar, .tar.gz, etc.

    # 1. Check file exists
    if [ ! -f "$filename" ]; then
        log_error "File $filename does not exist."
        return 1
    fi

    # 2. Check file is non-empty
    if [ ! -s "$filename" ]; then
        log_error "File $filename exists but is empty."
        return 1
    fi

    # 3. Check file is a valid tar archive
    if ! tar -tf "$filename" >/dev/null 2>&1; then
        log_error "File $filename is not a valid tar archive."
        return 1
    fi

    # 4. Check if already extracted
    if [ -d "$foldername" ]; then
        log_pass "$filename has already been extracted to $foldername/"
        return 0
    fi

    log_info "$filename exists and is valid, but not yet extracted."
    return 2
}

extract_tar_from_url() {
    local url="$1"
    local filename
    local extracted_files

    filename=$(basename "$url")

    check_tar_file "$url"
    status=$?
    if [ "$status" -eq 0 ]; then
        log_info "Already extracted. Skipping download."
        return 0
    elif [ "$status" -eq 1 ]; then
        log_info "File missing or invalid. Will download and extract."
    fi

    check_network_status || return 1

    log_info "Downloading $url..."
    wget -O "$filename" "$url" || {
        log_fail "Failed to download $filename"
        return 1
    }

    log_info "Extracting $filename..."
    tar -xvf "$filename" || {
        log_fail "Failed to extract $filename"
        return 1
    }

    extracted_files=$(tar -tf "$filename")
    if [ -z "$extracted_files" ]; then
        log_fail "No files were extracted from $filename."
        return 1
    else
        log_pass "Files extracted successfully:"
        echo "$extracted_files"
        return 0
    fi
}
