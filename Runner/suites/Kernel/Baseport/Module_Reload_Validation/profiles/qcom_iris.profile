#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="qcom_iris"
PROFILE_DESCRIPTION="Qualcomm Iris video module reload validation"
MODULE_NAME="qcom_iris"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="basic"

PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed"

MODULE_UNLOAD_CMD="modprobe -r qcom_iris"
MODULE_LOAD_CMD="modprobe qcom_iris"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="qcom_iris"
PROFILE_DEVICE_PATTERNS="/dev/video* /dev/media*"
PROFILE_SYSFS_PATTERNS="/sys/module/qcom_iris"
