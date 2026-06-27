# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

PROFILE_NAME="msm"
PROFILE_DESCRIPTION="Qualcomm MSM DRM / Adreno GPU driver reload validation"
MODULE_NAME="msm"

PROFILE_MODE_DEFAULT="basic"
PROFILE_REQUIRED_CMDS="modprobe rmmod grep ps sed"

PROFILE_QUIESCE_ONCE="yes"
PROFILE_QUIESCE_SERVICES="weston.service display-manager.service"
PROFILE_QUIESCE_PROC_PATTERNS="weston Xorg Xwayland kmscube modetest glmark2 glmark2-es2 glmark2-es2-drm es2gears glxgears vkmark"

PROFILE_DEVICE_PATTERNS="/dev/dri/* /dev/fb*"
PROFILE_QUIESCE_DEVICE_PATTERNS="$PROFILE_DEVICE_PATTERNS"

PROFILE_SYSFS_PATTERNS="/sys/module/msm /sys/class/drm /sys/kernel/debug/dri/*"

MODULE_UNLOAD_CMD="modprobe -r msm"
MODULE_LOAD_CMD="modprobe msm"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="msm"
PROFILE_EXPECT_PRESENT_AFTER_LOAD="msm"
