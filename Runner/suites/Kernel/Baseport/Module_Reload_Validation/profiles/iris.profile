#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="iris"
PROFILE_DESCRIPTION="Downstream Iris video overlay module reload validation"

IRIS_MODULE_NAME=""
for vname in iris iris_vpu; do
  if mrv_module_loaded "$vname" || modinfo "$vname" >/dev/null 2>&1; then
    IRIS_MODULE_NAME="$vname"
    break
  fi
done

if [ -n "$IRIS_MODULE_NAME" ]; then
  MODULE_NAME="$IRIS_MODULE_NAME"
  MODULE_RELOAD_SUPPORTED="yes"
  MODULE_UNLOAD_CMD="modprobe -r $IRIS_MODULE_NAME"
  MODULE_LOAD_CMD="modprobe $IRIS_MODULE_NAME"
  PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="$IRIS_MODULE_NAME"
else
  MODULE_NAME="iris"
  MODULE_RELOAD_SUPPORTED="no"
fi

PROFILE_MODE_DEFAULT="basic"
PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed"
PROFILE_DEVICE_PATTERNS="/dev/video* /dev/media*"
PROFILE_SYSFS_PATTERNS="/sys/module/iris /sys/module/iris_vpu"
