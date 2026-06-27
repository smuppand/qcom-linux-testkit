#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause

PROFILE_NAME="tc956x_pcie_eth"
PROFILE_DESCRIPTION="TC956x PCIe Ethernet module reload validation"
MODULE_NAME="tc956x_pcie_eth"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="basic"

PROFILE_REQUIRED_CMDS="modprobe rmmod ps sed"

MODULE_UNLOAD_CMD="modprobe -r tc956x_pcie_eth"
MODULE_LOAD_CMD="modprobe tc956x_pcie_eth"

PROFILE_EXPECT_ABSENT_AFTER_UNLOAD="tc956x_pcie_eth"
PROFILE_DEVICE_PATTERNS="/sys/class/net/*"
PROFILE_SYSFS_PATTERNS="/sys/module/tc956x_pcie_eth"
