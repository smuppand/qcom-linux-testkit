#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="spcom"
PROFILE_DESCRIPTION="Secure Processor communication module reload validation"
MODULE_NAME="spcom"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="spdaemon.service qseecomd.service keymaster-4-0.service"
PROFILE_PROC_PATTERNS="spdaemon qseecomd keymaster"
MODULE_UNLOAD_CMD="modprobe -r spcom"
MODULE_LOAD_CMD="modprobe spcom"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="spcom"
PROFILE_DEVICE_PATTERNS="/dev/spcom* /dev/qseecom*"
PROFILE_SYSFS_PATTERNS="/sys/module/spcom"
