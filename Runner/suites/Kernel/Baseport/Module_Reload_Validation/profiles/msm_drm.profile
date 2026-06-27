#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="msm_drm"
PROFILE_DESCRIPTION="Downstream MSM DRM display overlay module reload validation"
MODULE_NAME="msm_drm"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="weston.service display-manager.service"
PROFILE_PROC_PATTERNS="weston kmscube glmark2"
MODULE_UNLOAD_CMD="modprobe -r msm_drm"
MODULE_LOAD_CMD="modprobe msm_drm"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="msm_drm"
PROFILE_DEVICE_PATTERNS="/dev/dri/*"
PROFILE_SYSFS_PATTERNS="/sys/module/msm_drm /sys/class/drm/*"
