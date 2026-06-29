# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

PROFILE_NAME="msm_kgsl"
PROFILE_DESCRIPTION="Legacy Qualcomm KGSL GPU driver reload validation"
MODULE_NAME="msm_kgsl"

PROFILE_MODE_DEFAULT="basic"
PROFILE_REQUIRED_CMDS="modprobe rmmod grep ps sed"

if ! mrv_module_available "msm_kgsl"; then
  MODULE_RELOAD_SUPPORTED="no"
  MODULE_RELOAD_UNSUPPORTED_REASON="legacy KGSL driver msm_kgsl not present; modern Adreno platforms use MSM DRM driver msm"
else
  PROFILE_QUIESCE_SERVICES="weston.service display-manager.service"
  PROFILE_QUIESCE_PROC_PATTERNS="weston Xorg Xwayland glmark2 kmscube modetest es2gears glxgears vkmark"

  PROFILE_DEVICE_PATTERNS="/dev/kgsl-3d0 /dev/dri/*"
  PROFILE_SYSFS_PATTERNS="/sys/module/msm_kgsl /sys/class/kgsl/kgsl-3d0"

  PROFILE_UNLOAD_STACK="governor_msm_adreno_tz governor_gpubw_mon msm_kgsl"
  PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="msm_kgsl"
  PROFILE_EXPECT_PRESENT_AFTER_LOAD="msm_kgsl"

  module_reload_profile_setup_stack
fi
