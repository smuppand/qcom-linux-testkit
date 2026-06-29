#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="venus_core"
PROFILE_DESCRIPTION="Upstream Venus video module reload validation"
MODULE_NAME="venus_core"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="basic"

PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed"
MODULE_UNLOAD_CMD="modprobe -r venus_enc venus_dec venus_core"
MODULE_LOAD_CMD="modprobe venus_core"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="venus_enc venus_dec venus_core"
PROFILE_DEVICE_PATTERNS="/dev/video* /dev/media*"
PROFILE_SYSFS_PATTERNS="/sys/module/venus_core /sys/module/venus_enc /sys/module/venus_dec"
