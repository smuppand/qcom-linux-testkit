#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="dwmac_qcom_eth"
PROFILE_DESCRIPTION="Qualcomm DWMAC/STMMAC Ethernet module reload validation"
MODULE_NAME="dwmac_qcom_eth"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="basic"

PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed"
MODULE_UNLOAD_CMD="modprobe -r dwmac_qcom_eth stmmac_platform stmmac"
MODULE_LOAD_CMD="modprobe dwmac_qcom_eth"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="dwmac_qcom_eth stmmac_platform stmmac"
PROFILE_DEVICE_PATTERNS="/sys/class/net/*"
PROFILE_SYSFS_PATTERNS="/sys/module/dwmac_qcom_eth /sys/module/stmmac_platform /sys/module/stmmac"
