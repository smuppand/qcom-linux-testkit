#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="mvm"
PROFILE_DESCRIPTION="MVM DLKM reload validation"
MODULE_NAME="mvm"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="mvm.service"
PROFILE_PROC_PATTERNS="mvm"
MODULE_UNLOAD_CMD="modprobe -r mvm"
MODULE_LOAD_CMD="modprobe mvm"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="mvm"
PROFILE_SYSFS_PATTERNS="/sys/module/mvm"
