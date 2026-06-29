#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="ath12k_pci"
PROFILE_DESCRIPTION="ath12k PCI Wi-Fi module reload validation"
MODULE_NAME="ath12k_pci"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_QUIESCE_ONCE="yes"
PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="wpa_supplicant.service NetworkManager.service systemd-networkd.service"
PROFILE_PROC_PATTERNS="wpa_supplicant NetworkManager iwd"

MODULE_UNLOAD_CMD="modprobe -r ath12k_pci ath12k mac80211 cfg80211"
MODULE_LOAD_CMD="modprobe ath12k_pci"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="ath12k_pci ath12k"
PROFILE_DEVICE_PATTERNS="/sys/class/net/wlan* /sys/class/ieee80211/*"
PROFILE_SYSFS_PATTERNS="/sys/module/ath12k_pci /sys/module/ath12k /sys/module/mac80211 /sys/module/cfg80211"
