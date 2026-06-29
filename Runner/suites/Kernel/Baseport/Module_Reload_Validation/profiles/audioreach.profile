#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="audioreach"
PROFILE_DESCRIPTION="AudioReach downstream audio overlay module reload validation"
MODULE_NAME="snd_soc_qdsp6"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="audioserver.service pipewire.service pulseaudio.service"
PROFILE_PROC_PATTERNS="audioserver pipewire pulseaudio"
MODULE_UNLOAD_CMD="modprobe -r snd_soc_qdsp6 q6asm q6adm q6afe apr"
MODULE_LOAD_CMD="modprobe snd_soc_qdsp6"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="snd_soc_qdsp6"
PROFILE_DEVICE_PATTERNS="/dev/snd/*"
PROFILE_SYSFS_PATTERNS="/sys/module/snd_soc_qdsp6 /sys/module/q6asm /sys/module/q6adm /sys/module/q6afe /sys/module/apr"
