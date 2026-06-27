#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="camera"
PROFILE_DESCRIPTION="CAMX camera KMD overlay reload validation"

CAMERA_MODULE_NAME=""
for cname in camera camera_kmd camx_kmd; do
  if mrv_module_loaded "$cname" || modinfo "$cname" >/dev/null 2>&1; then
    CAMERA_MODULE_NAME="$cname"
    break
  fi
done

if [ -n "$CAMERA_MODULE_NAME" ]; then
  MODULE_NAME="$CAMERA_MODULE_NAME"
  MODULE_RELOAD_SUPPORTED="yes"
  MODULE_UNLOAD_CMD="modprobe -r $CAMERA_MODULE_NAME camss"
  MODULE_LOAD_CMD="modprobe $CAMERA_MODULE_NAME"
  PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="$CAMERA_MODULE_NAME"
else
  MODULE_NAME="camera"
  MODULE_RELOAD_SUPPORTED="no"
fi

PROFILE_MODE_DEFAULT="daemon_lifecycle"
PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="qmmf-server.service qmmf-recorder.service"
PROFILE_PROC_PATTERNS="qmmf-server qmmf-recorder gst-launch"
PROFILE_DEVICE_PATTERNS="/dev/video* /dev/media*"
PROFILE_SYSFS_PATTERNS="/sys/module/camera /sys/module/camera_kmd /sys/module/camx_kmd /sys/module/camss"

profile_quiesce() {
  iter_dir="$1"
  : "${iter_dir:=}"

  module_reload_stop_mask_kill_services "$PROFILE_SERVICES" "$PROFILE_PROC_PATTERNS" 20 "$PROFILE_NAME" || return 1

  if command -v pkill >/dev/null 2>&1; then
    pkill -f "gst-launch.*camera" 2>/dev/null || true
  fi

  sleep 2
  return 0
}
