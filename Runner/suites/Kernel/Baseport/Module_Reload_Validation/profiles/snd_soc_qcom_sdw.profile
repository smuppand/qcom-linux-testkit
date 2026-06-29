#!/bin/sh
#SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="snd_soc_qcom_sdw"
PROFILE_DESCRIPTION="Qualcomm ASoC/SoundWire stack reload validation"
MODULE_NAME="snd_soc_qcom_sdw"

PROFILE_MODE_DEFAULT="basic"
PROFILE_QUIESCE_ONCE="yes"
PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed grep readlink sort awk tr"

PROFILE_TOP_MODULE_CANDIDATES="snd_soc_sc8280xp"

PROFILE_QUIESCE_SERVICES="pipewire.service wireplumber.service pulseaudio.service"
PROFILE_PROC_PATTERNS="pipewire-pulse pipewire wireplumber pulseaudio aplay arecord speaker-test pw-play pw-record gst-launch"
PROFILE_QUIESCE_PROC_PATTERNS="$PROFILE_PROC_PATTERNS"

PROFILE_DEVICE_PATTERNS="/dev/snd/*"
PROFILE_QUIESCE_DEVICE_PATTERNS="$PROFILE_DEVICE_PATTERNS"

PROFILE_SYSFS_PATTERNS="/sys/module/snd_soc_sc8280xp /sys/module/snd_soc_qcom_sdw /sys/module/soundwire_qcom /sys/module/snd_soc_wsa883x /sys/bus/soundwire/devices/*"

module_reload_profile_setup_stack

profile_quiesce() {
  module_reload_profile_quiesce_resources "$PROFILE_NAME" "$1" 20
}

profile_smoke() {
  module_reload_profile_smoke_modules_present "$PROFILE_NAME" "$PROFILE_EXPECT_PRESENT_AFTER_LOAD"
}

