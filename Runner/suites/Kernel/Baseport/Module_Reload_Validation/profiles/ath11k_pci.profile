#!/bin/sh
#SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="ath11k_pci"
PROFILE_DESCRIPTION="ath11k PCI Wi-Fi module reload validation"
MODULE_NAME="ath11k_pci"

PROFILE_SKIP_IF_MODULES_LOADED="ath11k_ahb ath12k_pci"
PROFILE_UNLOAD_STACK="ath11k_pci ath11k mac80211 cfg80211"
PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="ath11k_pci ath11k"

PROFILE_MODE_DEFAULT="basic"
PROFILE_QUIESCE_ONCE="yes"
PROFILE_QUIESCE_SERVICES="wpa_supplicant.service NetworkManager.service systemd-networkd.service"
PROFILE_PROC_PATTERNS="wpa_supplicant NetworkManager iwd"
PROFILE_QUIESCE_PROC_PATTERNS="$PROFILE_PROC_PATTERNS"

PROFILE_DEVICE_PATTERNS="/sys/class/net/wlan* /sys/class/ieee80211/*"
PROFILE_SYSFS_PATTERNS="/sys/module/ath11k_pci /sys/module/ath11k /sys/module/mac80211 /sys/module/cfg80211"

module_reload_profile_setup_stack

profile_quiesce() {
  module_reload_profile_quiesce_resources "$PROFILE_NAME" "$1" 20
}
