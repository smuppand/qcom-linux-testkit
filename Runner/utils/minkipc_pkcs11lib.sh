#!/bin/sh
# shellcheck disable=SC2034

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Shared preparation and result helpers for MinkIPC QTEE PKCS#11 tests.
# functestlib.sh and lib_pkg_provider.sh must be sourced before this file.

MINKIPC_PKCS11_TA_UUID="FD02C9DA-306C-48C7-A49C-BBD827AE86EE"
MINKIPC_PKCS11_STORAGE_TA_UUIDS="B689F2A7-8ADF-477A-9F99-32E90C0AD0A2 731E279E-AAFB-4575-A771-38CAA6F0CCA6"
MINKIPC_PKCS11_EXPECTED_CASES="1000 1001 1002 1003 1004 1005 1006 1007 1008 1009 1010 1011 1012 1013 1014 1015 1017 1020 1022 1023 1024"

MINKIPC_PKCS11_CLIENT_PATH=""
MINKIPC_PKCS11_QTEE_DEVICE=""
MINKIPC_PKCS11_TA_PATH=""
MINKIPC_PKCS11_SFS_UNIT=""
MINKIPC_PKCS11_SUPPLICANT_UNIT=""
MINKIPC_PKCS11_SFS_STARTED_BY_TEST=0
MINKIPC_PKCS11_SUPPLICANT_STARTED_BY_TEST=0
MINKIPC_PKCS11_PREP_RESULT="FAIL"
MINKIPC_PKCS11_PREP_MESSAGE="runtime preparation was not completed"

MINKIPC_PKCS11_CASE_TOTAL=""
MINKIPC_PKCS11_CASE_FAILED=""
MINKIPC_PKCS11_SUBTEST_TOTAL=""
MINKIPC_PKCS11_SUBTEST_FAILED=""
MINKIPC_PKCS11_VALIDATION_MESSAGE=""

# Purpose: Locate a QTEE TA using the qtee_supplicant autoload search order.
# Arguments:
#   $1 - TA UUID without a filename extension.
# Output:
#   Prints the first matching .mbn or .b00 path.
# Returns:
#   0 when a TA file is found, otherwise 1.
find_qtee_ta() {
    fqta_uuid="$1"
    fqta_upper=$(printf '%s\n' "$fqta_uuid" | tr '[:lower:]' '[:upper:]')
    fqta_lower=$(printf '%s\n' "$fqta_uuid" | tr '[:upper:]' '[:lower:]')

    for fqta_name in "$fqta_uuid" "$fqta_upper" "$fqta_lower"; do
        for fqta_extension in mbn b00; do
            fqta_candidate="/data/$fqta_name.$fqta_extension"
            if [ -s "$fqta_candidate" ]; then
                printf '%s\n' "$fqta_candidate"
                return 0
            fi
        done
    done

    fqta_compatible_file=""
    for fqta_path in \
        /sys/firmware/devicetree/base/compatible \
        /proc/device-tree/compatible; do
        if [ -r "$fqta_path" ]; then
            fqta_compatible_file="$fqta_path"
            break
        fi
    done

    [ -n "$fqta_compatible_file" ] || return 1

    fqta_compatibles=$(tr '\000' '\n' < "$fqta_compatible_file" 2>/dev/null)
    for fqta_compatible in $fqta_compatibles; do
        fqta_platform=${fqta_compatible#*,}
        [ -n "$fqta_platform" ] || continue

        for fqta_name in "$fqta_uuid" "$fqta_upper" "$fqta_lower"; do
            for fqta_extension in mbn b00; do
                fqta_candidate="/lib/qtee-tas/$fqta_platform/$fqta_name.$fqta_extension"
                if [ -s "$fqta_candidate" ]; then
                    printf '%s\n' "$fqta_candidate"
                    return 0
                fi
            done
        done
    done

    return 1
}

# Purpose: Prepare packages required by the QTEE PKCS#11 tests.
# Arguments:
#   $1 - Normalized operating-system identifier.
# Side effects:
#   Debian and Ubuntu may install the minkipc-pkcs11 package set.
# Returns:
#   0 when packages are ready or image-provided components are expected.
#   1 on package preparation failure and sets MINKIPC_PKCS11_PREP_MESSAGE.
minkipc_pkcs11_prepare_packages() {
    mpp_os_id="$1"

    case "$mpp_os_id" in
        debian|ubuntu)
            for mpp_helper in \
                pkg_provider_init \
                pkg_lookup_package_set \
                pkg_ensure_optional_package_set_present; do
                if ! command -v "$mpp_helper" >/dev/null 2>&1; then
                    MINKIPC_PKCS11_PREP_MESSAGE="required package helper is unavailable: $mpp_helper"
                    return 1
                fi
            done

            if ! pkg_lookup_package_set minkipc-pkcs11 >/dev/null 2>&1; then
                MINKIPC_PKCS11_PREP_MESSAGE="minkipc-pkcs11 package mapping is unavailable for os=$mpp_os_id"
                return 1
            fi

            if ! pkg_provider_init; then
                MINKIPC_PKCS11_PREP_MESSAGE="package provider initialization failed"
                return 1
            fi

            mpp_old_upgrade="${PKG_PACKAGE_SET_UPGRADE-__unset__}"
            PKG_PACKAGE_SET_UPGRADE=0
            export PKG_PACKAGE_SET_UPGRADE

            if ! pkg_ensure_optional_package_set_present \
                minkipc-pkcs11 \
                qli-staging \
                trixie \
                --overlay; then
                case "$mpp_old_upgrade" in
                    __unset__)
                        unset PKG_PACKAGE_SET_UPGRADE
                        ;;
                    *)
                        PKG_PACKAGE_SET_UPGRADE="$mpp_old_upgrade"
                        export PKG_PACKAGE_SET_UPGRADE
                        ;;
                esac
                MINKIPC_PKCS11_PREP_MESSAGE="failed to prepare the QTEE PKCS#11 package set"
                return 1
            fi

            case "$mpp_old_upgrade" in
                __unset__)
                    unset PKG_PACKAGE_SET_UPGRADE
                    ;;
                *)
                    PKG_PACKAGE_SET_UPGRADE="$mpp_old_upgrade"
                    export PKG_PACKAGE_SET_UPGRADE
                    ;;
            esac
            log_pass "QTEE PKCS#11 package set is ready"
            ;;
        *)
            log_info "Package installation is not enabled for os=$mpp_os_id, using image-provided QTEE components"
            ;;
    esac

    return 0
}

# Purpose: Validate and prepare the complete runtime shared by PKCS#11 tests.
# Arguments:
#   $1 - Requested xtest_qtee path or command name, or an empty string.
#   $2 - Normalized operating-system identifier.
# Side effects:
#   May install packages and start inactive SFS or qtee_supplicant services.
# Outputs:
#   Sets MINKIPC_PKCS11_CLIENT_PATH and related runtime-state variables.
# Returns:
#   0 when the runtime is ready. Returns 1 and sets
#   MINKIPC_PKCS11_PREP_RESULT and MINKIPC_PKCS11_PREP_MESSAGE otherwise.
minkipc_pkcs11_prepare_runtime() {
    mpr_requested_client="$1"
    mpr_os_id="$2"

    MINKIPC_PKCS11_CLIENT_PATH=""
    MINKIPC_PKCS11_QTEE_DEVICE=""
    MINKIPC_PKCS11_TA_PATH=""
    MINKIPC_PKCS11_SFS_UNIT=""
    MINKIPC_PKCS11_SUPPLICANT_UNIT=""
    MINKIPC_PKCS11_SFS_STARTED_BY_TEST=0
    MINKIPC_PKCS11_SUPPLICANT_STARTED_BY_TEST=0
    MINKIPC_PKCS11_PREP_RESULT="FAIL"
    MINKIPC_PKCS11_PREP_MESSAGE="runtime preparation was not completed"

    minkipc_pkcs11_prepare_packages "$mpr_os_id" || return 1

    if [ -n "$mpr_requested_client" ]; then
        case "$mpr_requested_client" in
            */*)
                MINKIPC_PKCS11_CLIENT_PATH="$mpr_requested_client"
                ;;
            *)
                MINKIPC_PKCS11_CLIENT_PATH=$(command -v "$mpr_requested_client" 2>/dev/null || true)
                ;;
        esac
    else
        MINKIPC_PKCS11_CLIENT_PATH=$(command -v xtest_qtee 2>/dev/null || true)
    fi

    if [ -z "$MINKIPC_PKCS11_CLIENT_PATH" ] || [ ! -x "$MINKIPC_PKCS11_CLIENT_PATH" ]; then
        case "$mpr_os_id" in
            debian|ubuntu)
                MINKIPC_PKCS11_PREP_RESULT="FAIL"
                MINKIPC_PKCS11_PREP_MESSAGE="xtest_qtee is missing after package preparation"
                ;;
            *)
                MINKIPC_PKCS11_PREP_RESULT="SKIP"
                MINKIPC_PKCS11_PREP_MESSAGE="xtest_qtee is not provisioned on this image"
                ;;
        esac
        return 1
    fi
    log_pass "xtest_qtee binary found: $MINKIPC_PKCS11_CLIENT_PATH"

    for mpr_device in /dev/tee0 /dev/qcomtee /dev/qcomtee0 /dev/smcinvoke; do
        if [ -c "$mpr_device" ]; then
            MINKIPC_PKCS11_QTEE_DEVICE="$mpr_device"
            break
        fi
    done

    if [ -z "$MINKIPC_PKCS11_QTEE_DEVICE" ]; then
        MINKIPC_PKCS11_PREP_RESULT="SKIP"
        MINKIPC_PKCS11_PREP_MESSAGE="no QCOMTEE or SMCInvoke character device was found"
        return 1
    fi
    if [ ! -r "$MINKIPC_PKCS11_QTEE_DEVICE" ] || [ ! -w "$MINKIPC_PKCS11_QTEE_DEVICE" ]; then
        MINKIPC_PKCS11_PREP_MESSAGE="current user cannot read and write $MINKIPC_PKCS11_QTEE_DEVICE"
        return 1
    fi
    log_pass "QTEE device is accessible: $MINKIPC_PKCS11_QTEE_DEVICE"

    MINKIPC_PKCS11_TA_PATH=$(find_qtee_ta "$MINKIPC_PKCS11_TA_UUID" 2>/dev/null || true)
    if [ -z "$MINKIPC_PKCS11_TA_PATH" ]; then
        MINKIPC_PKCS11_PREP_RESULT="SKIP"
        MINKIPC_PKCS11_PREP_MESSAGE="PKCS#11 TA $MINKIPC_PKCS11_TA_UUID is not provisioned under /data or the runtime-compatible /lib/qtee-tas directory"
        return 1
    fi
    log_pass "PKCS#11 Trusted Application found: $MINKIPC_PKCS11_TA_PATH"

    for mpr_sfs in sfsconfig minkipc-sfsconfig sfs-config; do
        if systemd_service_exists "$mpr_sfs"; then
            MINKIPC_PKCS11_SFS_UNIT="$mpr_sfs"
            break
        fi
    done

    if [ -n "$MINKIPC_PKCS11_SFS_UNIT" ]; then
        if systemd_service_is_active "$MINKIPC_PKCS11_SFS_UNIT"; then
            log_pass "Secure-filesystem initialization is active: $MINKIPC_PKCS11_SFS_UNIT"
        elif [ "$(id -u)" -eq 0 ] && systemd_service_start_safe "$MINKIPC_PKCS11_SFS_UNIT"; then
            MINKIPC_PKCS11_SFS_STARTED_BY_TEST=1
            log_pass "Started secure-filesystem initialization for this test: $MINKIPC_PKCS11_SFS_UNIT"
        else
            MINKIPC_PKCS11_PREP_MESSAGE="secure-filesystem initialization is not successful: $MINKIPC_PKCS11_SFS_UNIT"
            return 1
        fi
    else
        log_warn "No SFS systemd unit was found, validating secure-storage directories directly"
    fi

    for mpr_secure_dir in \
        /var/lib/tee/qtee_supplicant \
        /var/lib/qtee_supplicant/vendor/tzstorage; do
        if [ ! -d "$mpr_secure_dir" ]; then
            MINKIPC_PKCS11_PREP_MESSAGE="required secure-storage directory is missing: $mpr_secure_dir"
            return 1
        fi
        log_pass "Secure-storage directory exists: $mpr_secure_dir"
    done

    if command -v findmnt >/dev/null 2>&1 && findmnt -n /var/lib/tee >/dev/null 2>&1; then
        log_pass "Persistent TEE storage is mounted at /var/lib/tee"
    else
        log_info "/var/lib/tee is not a separate mount, continuing with the available secure-storage path"
    fi

    for mpr_supplicant in qteesupplicant qtee-supplicant minkipc-qteesupplicant; do
        if systemd_service_exists "$mpr_supplicant"; then
            MINKIPC_PKCS11_SUPPLICANT_UNIT="$mpr_supplicant"
            break
        fi
    done

    mpr_supplicant_running=0
    for mpr_process in qtee_supplicant qteesupplicant; do
        if get_pid "$mpr_process" >/dev/null 2>&1; then
            mpr_supplicant_running=1
            break
        fi
    done

    if [ -n "$MINKIPC_PKCS11_SUPPLICANT_UNIT" ]; then
        if systemd_service_is_active "$MINKIPC_PKCS11_SUPPLICANT_UNIT" || \
           [ "$mpr_supplicant_running" -eq 1 ]; then
            log_pass "qtee_supplicant is active: $MINKIPC_PKCS11_SUPPLICANT_UNIT"
        elif [ "$(id -u)" -eq 0 ] && systemd_service_start_safe "$MINKIPC_PKCS11_SUPPLICANT_UNIT"; then
            MINKIPC_PKCS11_SUPPLICANT_STARTED_BY_TEST=1
            log_pass "Started qtee_supplicant for this test: $MINKIPC_PKCS11_SUPPLICANT_UNIT"
        else
            MINKIPC_PKCS11_PREP_MESSAGE="qtee_supplicant could not be started: $MINKIPC_PKCS11_SUPPLICANT_UNIT"
            return 1
        fi
    elif [ "$mpr_supplicant_running" -eq 1 ]; then
        log_pass "qtee_supplicant process is running without a systemd unit"
    else
        MINKIPC_PKCS11_PREP_MESSAGE="qtee_supplicant is not running and no service unit was found"
        return 1
    fi

    MINKIPC_PKCS11_PREP_RESULT="PASS"
    MINKIPC_PKCS11_PREP_MESSAGE="runtime preparation completed"
    return 0
}

# Purpose: Restore services started by minkipc_pkcs11_prepare_runtime().
# Arguments:
#   None. Uses the MINKIPC_PKCS11_*_STARTED_BY_TEST state variables.
# Side effects:
#   Stops only services that the current test invocation started.
# Returns:
#   0 after attempting restoration. Restoration failures are logged.
minkipc_pkcs11_restore_runtime() {
    if [ "$MINKIPC_PKCS11_SUPPLICANT_STARTED_BY_TEST" -eq 1 ] && \
       [ -n "$MINKIPC_PKCS11_SUPPLICANT_UNIT" ]; then
        if systemd_service_stop_safe "$MINKIPC_PKCS11_SUPPLICANT_UNIT"; then
            log_info "Restored qtee_supplicant service to its original inactive state"
        else
            log_warn "Could not restore qtee_supplicant service state: $MINKIPC_PKCS11_SUPPLICANT_UNIT"
        fi
        MINKIPC_PKCS11_SUPPLICANT_STARTED_BY_TEST=0
    fi

    if [ "$MINKIPC_PKCS11_SFS_STARTED_BY_TEST" -eq 1 ] && \
       [ -n "$MINKIPC_PKCS11_SFS_UNIT" ]; then
        if systemd_service_stop_safe "$MINKIPC_PKCS11_SFS_UNIT"; then
            log_info "Restored SFS service to its original inactive state"
        else
            log_warn "Could not restore SFS service state: $MINKIPC_PKCS11_SFS_UNIT"
        fi
        MINKIPC_PKCS11_SFS_STARTED_BY_TEST=0
    fi

    return 0
}

# Purpose: Install signal and exit traps that restore PKCS#11 runtime state.
# Arguments:
#   None.
# Side effects:
#   Replaces the shell EXIT, HUP, INT, and TERM traps. Callers that need extra
#   cleanup may replace only the EXIT trap after calling this function.
# Returns:
#   0 after installing the traps.
minkipc_pkcs11_install_cleanup_traps() {
    trap 'minkipc_pkcs11_restore_runtime' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    return 0
}

# Purpose: Identify storage-test TAs required by xtest_qtee --clear-storage.
# Arguments:
#   None. Uses MINKIPC_PKCS11_STORAGE_TA_UUIDS.
# Output:
#   Prints one missing TA UUID per line and prints nothing when all are found.
# Returns:
#   0 after checking every required TA.
minkipc_pkcs11_missing_clear_storage_tas() {
    for mmcst_uuid in $MINKIPC_PKCS11_STORAGE_TA_UUIDS; do
        if ! find_qtee_ta "$mmcst_uuid" >/dev/null 2>&1; then
            printf '%s\n' "$mmcst_uuid"
        fi
    done

    return 0
}

# Purpose: Parse the final case and subtest summaries from an xtest_qtee log.
# Arguments:
#   $1 - Readable xtest_qtee output log.
# Outputs:
#   Sets MINKIPC_PKCS11_CASE_TOTAL, MINKIPC_PKCS11_CASE_FAILED,
#   MINKIPC_PKCS11_SUBTEST_TOTAL, and MINKIPC_PKCS11_SUBTEST_FAILED.
# Returns:
#   0 after parsing. Missing summaries are represented by empty output values.
minkipc_pkcs11_parse_summary() {
    mps_log="$1"

    mps_case_values=$(awk '
        /test case(s)? of which [0-9]+ failed/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "test" && $(i + 1) ~ /^case/) {
                    total = $(i - 1)
                    failed = $(i + 4)
                }
            }
        }
        END {
            if (total != "")
                print total, failed
        }
    ' "$mps_log")

    mps_subtest_values=$(awk '
        /subtest(s)? of which [0-9]+ failed/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^subtests?$/) {
                    total = $(i - 1)
                    failed = $(i + 3)
                }
            }
        }
        END {
            if (total != "")
                print total, failed
        }
    ' "$mps_log")

    MINKIPC_PKCS11_CASE_TOTAL=$(printf '%s\n' "$mps_case_values" | awk '{print $1}')
    MINKIPC_PKCS11_CASE_FAILED=$(printf '%s\n' "$mps_case_values" | awk '{print $2}')
    MINKIPC_PKCS11_SUBTEST_TOTAL=$(printf '%s\n' "$mps_subtest_values" | awk '{print $1}')
    MINKIPC_PKCS11_SUBTEST_FAILED=$(printf '%s\n' "$mps_subtest_values" | awk '{print $2}')

    return 0
}

# Purpose: Report expected top-level PKCS#11 cases that did not report OK.
# Arguments:
#   $1 - Readable xtest_qtee output log.
#   $2 - Optional space-separated case ID manifest. The QTEE manifest is used
#        when this argument is omitted or empty.
# Output:
#   Prints one missing case ID per line.
# Returns:
#   0 after checking the complete manifest.
minkipc_pkcs11_missing_expected_cases() {
    mmec_log="$1"
    mmec_expected="${2:-$MINKIPC_PKCS11_EXPECTED_CASES}"

    # Intentional splitting of the validated space-separated case manifest.
    # shellcheck disable=SC2086
    for mmec_case in $mmec_expected; do
        if ! grep -Eq "^[[:space:]]*pkcs11_${mmec_case}[[:space:]]+OK[[:space:]]*$" "$mmec_log"; then
            printf '%s\n' "$mmec_case"
        fi
    done

    return 0
}

# Purpose: Validate an xtest_qtee PKCS#11 summary and expected case manifest.
# Arguments:
#   $1 - Readable xtest_qtee output log.
#   $2 - Optional space-separated case manifest. Pass "-" to validate only
#        the summary without enforcing specific case IDs.
# Outputs:
#   Sets parsed summary variables and MINKIPC_PKCS11_VALIDATION_MESSAGE.
# Returns:
#   0 when the run is valid, otherwise 1 with the failure reason in
#   MINKIPC_PKCS11_VALIDATION_MESSAGE.
minkipc_pkcs11_validate_log() {
    mvl_log="$1"
    mvl_expected="${2:-$MINKIPC_PKCS11_EXPECTED_CASES}"
    MINKIPC_PKCS11_VALIDATION_MESSAGE=""

    minkipc_pkcs11_parse_summary "$mvl_log"

    if [ -z "$MINKIPC_PKCS11_CASE_TOTAL" ] || \
       [ -z "$MINKIPC_PKCS11_CASE_FAILED" ] || \
       [ -z "$MINKIPC_PKCS11_SUBTEST_TOTAL" ] || \
       [ -z "$MINKIPC_PKCS11_SUBTEST_FAILED" ]; then
        MINKIPC_PKCS11_VALIDATION_MESSAGE="xtest_qtee did not emit a complete test summary"
        return 1
    fi

    if [ "$MINKIPC_PKCS11_CASE_FAILED" -ne 0 ] || \
       [ "$MINKIPC_PKCS11_SUBTEST_FAILED" -ne 0 ]; then
        MINKIPC_PKCS11_VALIDATION_MESSAGE="summary reports cases=$MINKIPC_PKCS11_CASE_TOTAL failed_cases=$MINKIPC_PKCS11_CASE_FAILED subtests=$MINKIPC_PKCS11_SUBTEST_TOTAL failed_subtests=$MINKIPC_PKCS11_SUBTEST_FAILED"
        return 1
    fi

    if [ "$MINKIPC_PKCS11_CASE_TOTAL" -eq 0 ]; then
        MINKIPC_PKCS11_VALIDATION_MESSAGE="the supplied filters selected no QTEE PKCS#11 test cases"
        return 1
    fi

    if [ "$mvl_expected" != "-" ]; then
        mvl_missing=$(minkipc_pkcs11_missing_expected_cases "$mvl_log" "$mvl_expected")
        if [ -n "$mvl_missing" ]; then
            mvl_missing=$(printf '%s\n' "$mvl_missing" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
            MINKIPC_PKCS11_VALIDATION_MESSAGE="expected QTEE PKCS#11 cases did not pass: $mvl_missing"
            return 1
        fi
    fi

    MINKIPC_PKCS11_VALIDATION_MESSAGE="cases=$MINKIPC_PKCS11_CASE_TOTAL subtests=$MINKIPC_PKCS11_SUBTEST_TOTAL"
    return 0
}

# Purpose: Scan the kernel log for QCOMTEE, SMCInvoke, and RPMB errors.
# Arguments:
#   $1 - Directory where dmesg scan artifacts will be stored.
# Side effects:
#   Writes artifacts using the shared scan_dmesg_errors() helper.
# Returns:
#   0 when relevant errors are found, otherwise 1. This matches the existing
#   scan_dmesg_errors() return convention.
minkipc_pkcs11_scan_dmesg() {
    scan_dmesg_errors \
        "$1" \
        'qcomtee|qcom_tee|qcom-tee|qtee|smcinvoke|rpmb' \
        'optional|not supported|deferred probe|B689F2A7-8ADF-477A-9F99-32E90C0AD0A2|731E279E-AAFB-4575-A771-38CAA6F0CCA6'
}

# Purpose: Record, log, and exit with the final result of a PKCS#11 test.
# Arguments:
#   $1 - PASS, SKIP, or FAIL result.
#   $2 - Human-readable result message.
#   $3 - Process exit status.
# Expected globals:
#   TESTNAME - Test name written to logs and the result file.
#   RES_FILE - Result-file path.
# Side effects:
#   Writes the result file and restores services started by the test.
# Returns:
#   Does not return. Exits with the status supplied in $3.
finish_test() {
    ft_result="$1"
    ft_message="$2"
    ft_rc="$3"

    case "$ft_result" in
        PASS)
            log_pass "$TESTNAME PASS: $ft_message"
            ;;
        SKIP)
            log_skip "$TESTNAME SKIP: $ft_message"
            ;;
        *)
            ft_result="FAIL"
            log_fail "$TESTNAME FAIL: $ft_message"
            ;;
    esac

    echo "$TESTNAME $ft_result" > "$RES_FILE"
    minkipc_pkcs11_restore_runtime
    exit "$ft_rc"
}

# Purpose: Record an argument or configuration failure before test execution.
# Arguments:
#   $1 - Human-readable failure message.
# Expected globals:
#   TESTNAME - Test name written to logs and the result file.
#   RES_FILE - Result-file path.
# Side effects:
#   Delegates result logging, result-file creation, and exit to finish_test().
# Returns:
#   Does not return. Records FAIL and exits with status 1.
write_early_failure() {
    finish_test FAIL "$1" 1
}
