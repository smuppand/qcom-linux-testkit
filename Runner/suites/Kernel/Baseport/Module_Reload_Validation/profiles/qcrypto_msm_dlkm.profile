#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="qcrypto_msm_dlkm"
PROFILE_DESCRIPTION="QCrypto MSM DLKM reload validation"
MODULE_NAME="qcrypto_msm_dlkm"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="qcrypto.service"
PROFILE_PROC_PATTERNS="qcrypto"
MODULE_UNLOAD_CMD="modprobe -r qcrypto_msm_dlkm"
MODULE_LOAD_CMD="modprobe qcrypto_msm_dlkm"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="qcrypto_msm_dlkm"
PROFILE_SYSFS_PATTERNS="/sys/module/qcrypto_msm_dlkm"
