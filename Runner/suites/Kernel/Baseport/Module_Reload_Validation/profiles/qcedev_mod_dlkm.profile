#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="qcedev_mod_dlkm"
PROFILE_DESCRIPTION="QCEDEV crypto DLKM reload validation"
MODULE_NAME="qcedev_mod_dlkm"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="basic"

PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed"
MODULE_UNLOAD_CMD="modprobe -r qcedev_mod_dlkm qce50_dlkm"
MODULE_LOAD_CMD="modprobe qcedev_mod_dlkm"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="qcedev_mod_dlkm qce50_dlkm"
PROFILE_DEVICE_PATTERNS="/dev/qce* /dev/qcedev*"
PROFILE_SYSFS_PATTERNS="/sys/module/qcedev_mod_dlkm /sys/module/qce50_dlkm"
