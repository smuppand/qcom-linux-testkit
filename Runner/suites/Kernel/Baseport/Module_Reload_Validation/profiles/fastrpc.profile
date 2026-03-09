#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

PROFILE_NAME="fastrpc"
PROFILE_DESCRIPTION="FastRPC module reload validation"
MODULE_NAME="fastrpc"

MODULE_RELOAD_SUPPORTED="yes"
PROFILE_MODE_DEFAULT="daemon_lifecycle"

PROFILE_REQUIRED_CMDS="modprobe rmmod systemctl ps sed"
PROFILE_SERVICES="adsprpcd.service cdsprpcd.service"
PROFILE_PROC_PATTERNS="/usr/bin/adsprpcd /usr/bin/cdsprpcd"
PROFILE_DEVICE_PATTERNS="/dev/fastrpc-* /dev/*dsp*"
PROFILE_SYSFS_PATTERNS="/sys/module/fastrpc /sys/class/remoteproc/*"
