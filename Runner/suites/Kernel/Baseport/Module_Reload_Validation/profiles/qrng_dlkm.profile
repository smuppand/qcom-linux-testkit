#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="qrng_dlkm"
PROFILE_DESCRIPTION="QRNG DLKM reload validation"
MODULE_NAME="qrng_dlkm"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="qrng.service"
PROFILE_PROC_PATTERNS="qrng"
MODULE_UNLOAD_CMD="modprobe -r qrng_dlkm"
MODULE_LOAD_CMD="modprobe qrng_dlkm"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="qrng_dlkm"
PROFILE_SYSFS_PATTERNS="/sys/module/qrng_dlkm"
