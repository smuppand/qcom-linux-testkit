#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# fastcv_prepare_runtime_packages
# Ensure the FastCV runtime package set on supported host distributions.
# Inputs: none. Output: no machine-readable stdout contract.
# Returns: 0 when packages are ready, 1 when required recovery fails, and 2
# when the target is an image-managed or otherwise unsupported distribution.
# Side effects: may configure Qualcomm RPM repositories on CentOS/RHEL and may
# install mapped packages through lib_pkg_provider.sh. Package-set upgrades are
# disabled for this operation and the prior policy is restored before return.
# Yocto remains unchanged.
fastcv_prepare_runtime_packages() {
    fcprp_os_id="$(pkg_detect_os_id)"

    for fcprp_helper in \
        pkg_provider_init \
        pkg_ensure_host_distro_package_set_present \
        pkg_ensure_required_package_set_present \
        pkg_package_recovery_supported_os; do
        if ! command -v "$fcprp_helper" >/dev/null 2>&1; then
            log_error "FastCV package preparation helper is unavailable: $fcprp_helper"
            return 1
        fi
    done

    if ! pkg_package_recovery_supported_os "$fcprp_os_id"; then
        log_info "[FASTCV-PACKAGES] action=image-provided os=$fcprp_os_id set=fastcv-runtime"
        return 2
    fi

    if ! pkg_provider_init; then
        log_error "FastCV package provider initialization failed"
        return 1
    fi

    fcprp_previous_set_upgrade="$PKG_PACKAGE_SET_UPGRADE"
    PKG_PACKAGE_SET_UPGRADE=0
    fcprp_rc=0

    case "$fcprp_os_id" in
        centos|rhel)
            if ! command -v pkg_ensure_qualcomm_rpm_repository >/dev/null 2>&1; then
                log_error "FastCV RPM repository preparation helper is unavailable"
                fcprp_rc=1
            elif ! pkg_ensure_required_package_set_present \
                fastcv-rpm-prerequisites; then
                log_error "FastCV EPEL repository prerequisite installation failed, os=$fcprp_os_id package=epel-release"
                fcprp_rc=1
            elif ! command -v pkg_rpm_repository_enabled >/dev/null 2>&1; then
                log_error "FastCV RPM repository verification helper is unavailable"
                fcprp_rc=1
            elif ! pkg_rpm_repository_enabled epel; then
                log_error "FastCV EPEL repository is not enabled after installing epel-release, os=$fcprp_os_id repository=epel"
                fcprp_rc=1
            elif ! pkg_ensure_qualcomm_rpm_repository; then
                fcprp_rc=1
            fi
            ;;
    esac

    if [ "$fcprp_rc" -eq 0 ] &&
       ! pkg_ensure_host_distro_package_set_present fastcv-runtime; then
        fcprp_rc=1
    fi

    PKG_PACKAGE_SET_UPGRADE="$fcprp_previous_set_upgrade"

    if [ "$fcprp_rc" -ne 0 ]; then
        return "$fcprp_rc"
    fi

    log_info "[FASTCV-PACKAGES] action=ready os=$fcprp_os_id set=fastcv-runtime upgrades=disabled"
    return 0
}
