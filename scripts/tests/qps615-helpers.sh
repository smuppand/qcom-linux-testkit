#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Host regression checks. EFI writes and mount operations are always mocked.
set -eu

REPO=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
# shellcheck disable=SC1091
. "$REPO/Runner/utils/lib_system.sh"
# shellcheck disable=SC1091
. "$REPO/Runner/utils/lib_ethernet.sh"

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

# log_info <message>
#   Suppress library diagnostics in host checks. No output or side effects.
log_info() {
    :
}

# log_warn <message>
#   Suppress fixture diagnostics. No output or side effects.
log_warn() {
    :
}

# log_pass <message>
#   Suppress fixture diagnostics. No output or side effects.
log_pass() {
    :
}

# efi_mount_exists / efi_mount_options
#   Read mock mount state. Never inspect or change the host EFI filesystem.
efi_mount_exists() {
    [ "$(cat "$FIXTURE/mount-state")" != "absent" ]
}

# efi_mount_options
#   Print the fixture mount mode. No side effects.
efi_mount_options() {
    cat "$FIXTURE/mount-state"
}

# mount <arguments...>
#   Model successful and failed mounts in a fixture file, log all mutations.
mount() {
    printf 'mount %s\n' "$*" >>"$FIXTURE/actions"
    case "$*" in
        *remount,ro*)
            [ "$SCENARIO" != "restore-failure" ] || return 1
            printf '%s\n' ro >"$FIXTURE/mount-state"
            ;;
        *)
            [ "$SCENARIO" != "mount-failure" ] || return 1
            printf '%s\n' rw >"$FIXTURE/mount-state"
            ;;
    esac
}

# umount <path>
#   Guard against unexpected unmounts without touching the host mount state.
umount() {
    printf 'umount %s\n' "$*" >>"$FIXTURE/actions"
    return 1
}

# sync
#   Record synchronization without invoking the host command.
sync() {
    printf '%s\n' sync >>"$FIXTURE/actions"
}

# efivar <arguments...>
#   Model list/print/write against files, preserving the real shared parsing
#   and payload-writing helpers. No host EFI command is invoked.
efivar() {
    case "$1" in
        -l)
            [ "$SCENARIO" != "list-failure" ] || return 1
            if [ "$SCENARIO" = "ambiguous" ]; then
                printf '%s\n' "11111111-1111-1111-1111-111111111111-VendorDtbOverlays"
            fi
            if [ -s "$FIXTURE/variable" ]; then
                cat "$FIXTURE/variable"
            fi
            ;;
        -n)
            case "$3" in
                -p)
                    [ "$SCENARIO" != "read-failure" ] || return 1
                    [ "$SCENARIO" != "verify-failure" ] || return 1
                    [ "$2" = "$(cat "$FIXTURE/variable")" ] || return 1
                    od -An -tx1 -v "$FIXTURE/payload"
                    ;;
                -w)
                    printf 'write %s\n' "$2" >>"$FIXTURE/actions"
                    [ "$SCENARIO" != "write-failure" ] || return 1
                    [ "$(wc -c <"$5" | tr -d '[:space:]')" = "7" ]
                    [ "$(cat "$5")" = "staging" ]
                    printf '%s\n' "$2" >"$FIXTURE/variable"
                    cp "$5" "$FIXTURE/payload"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

# check_overlay <scenario> <mount-state> <expected-return> <write-count>
#   Execute real preparation against mock commands and verify retained mounts.
check_overlay() {
    SCENARIO="$1"
    initial_mount="$2"
    expected_status="$3"
    expected_writes="$4"
    EFIVARFS_PATH="$FIXTURE/efivars"
    mkdir -p "$EFIVARFS_PATH"
    EFIVARFS_RESTORE_RO=0
    printf '%s\n' "$initial_mount" >"$FIXTURE/mount-state"
    : >"$FIXTURE/actions"
    : >"$FIXTURE/variable"
    printf '%s' base >"$FIXTURE/payload"
    case "$SCENARIO" in
        existing-*|ambiguous|read-failure|restore-failure)
            printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-VendorDtbOverlays' >"$FIXTURE/variable"
            ;;
    esac
    if [ "$SCENARIO" = "existing-selected" ]; then
        printf '%s' staging >"$FIXTURE/payload"
    fi
    actual_status=0
    ethv_qps615_prepare_overlay "$FIXTURE/$SCENARIO" || actual_status=$?
    [ "$actual_status" = "$expected_status" ] || {
        printf '%s\n' "$SCENARIO expected rc=$expected_status got=$actual_status: $QPS615_OVERLAY_REASON" >&2
        exit 1
    }
    writes=$(awk '/^write / { n++ } END { print n+0 }' "$FIXTURE/actions")
    [ "$writes" = "$expected_writes" ]
    if grep -q '^umount ' "$FIXTURE/actions"; then
        printf '%s\n' "$SCENARIO unexpectedly attempted to unmount efivarfs" >&2
        exit 1
    fi
    expected_mount="$initial_mount"
    if [ "$initial_mount" = "absent" ] && [ "$SCENARIO" != "mount-failure" ]; then
        expected_mount="rw"
        grep -Fxq "mount -t efivarfs none $EFIVARFS_PATH" "$FIXTURE/actions"
    fi
    case "$SCENARIO" in
        restore-failure)
            [ "$(cat "$FIXTURE/mount-state")" = "rw" ]
            case "$QPS615_OVERLAY_REASON" in
                *'restoring EFI mount to read-only failed'*)
                    ;;
                *)
                    exit 1
                    ;;
            esac
            ;;
        *)
            [ "$(cat "$FIXTURE/mount-state")" = "$expected_mount" ]
            [ "$EFIVARFS_RESTORE_RO" = 0 ]
            ;;
    esac
    if [ "$actual_status" = 4 ]; then
        [ -s "$FIXTURE/$SCENARIO/before_qps615_overlay.tsv" ]
        grep -q '^sync$' "$FIXTURE/actions"
        case "$SCENARIO" in
            existing-*)
                grep -q '^write aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-VendorDtbOverlays$' "$FIXTURE/actions"
                ;;
            *)
                grep -q '^write 882f8c2b-9646-435f-8de5-f208ff80c1bd-VendorDtbOverlays$' "$FIXTURE/actions"
                ;;
        esac
    fi
    printf 'PASS overlay %s\n' "$SCENARIO"
}

check_overlay new-variable absent 4 1

# Repeated preparation reuses the retained mount and selected EFI variable.
ethv_qps615_prepare_overlay "$FIXTURE/repeated"
[ "$(cat "$FIXTURE/mount-state")" = rw ]
[ "$(awk '/^mount / { n++ } END { print n+0 }' "$FIXTURE/actions")" = 1 ]
[ "$(awk '/^write / { n++ } END { print n+0 }' "$FIXTURE/actions")" = 1 ]
if grep -q '^umount ' "$FIXTURE/actions"; then
    printf '%s\n' 'Repeated preparation unexpectedly attempted to unmount efivarfs' >&2
    exit 1
fi
printf '%s\n' 'PASS repeated preparation retains mount without rewriting'

check_overlay existing-ro ro 4 1
check_overlay existing-rw rw 4 1
check_overlay existing-selected absent 0 0
check_overlay mount-failure absent 1 0
check_overlay list-failure absent 2 0
check_overlay ambiguous absent 2 0
check_overlay read-failure ro 2 0
check_overlay write-failure absent 1 1
check_overlay verify-failure absent 1 1
check_overlay restore-failure ro 1 1

# Read-only discovery must not mount or create an absent variable.
SCENARIO="readonly"
EFIVARFS_RESTORE_RO=0
printf '%s\n' absent >"$FIXTURE/mount-state"
: >"$FIXTURE/actions"
: >"$FIXTURE/variable"
readonly_status=0
ethv_qps615_collect_overlay_state "$FIXTURE/readonly" || readonly_status=$?
[ "$readonly_status" = 2 ]
[ ! -s "$FIXTURE/actions" ]
printf '%s\n' rw >"$FIXTURE/mount-state"
readonly_status=0
ethv_qps615_collect_overlay_state "$FIXTURE/readonly" || readonly_status=$?
[ "$readonly_status" = 1 ]
[ "$QPS615_OVERLAY_STATE" = absent ]
[ ! -s "$FIXTURE/actions" ]
printf '%s\n' 'PASS read-only inspection'

# dt_list_compatible_nodes
#   Model legacy PCI-only inventory with no runtime DT nodes. Return 1.
dt_list_compatible_nodes() {
    return 1
}

# find_image_firmware
#   Print the mock firmware path. No side effects.
find_image_firmware() {
    printf '%s\n' "$FIXTURE/firmware"
}

# find_kernel_module
#   Model a PCI-only image with no optional MAC module. Return 1.
find_kernel_module() {
    return 1
}

# pci_device <path> <device-id>
#   Create one mock PCI device and its bus link. No host sysfs is written.
pci_device() {
    mkdir -p "$1"
    printf '%s\n' 0x1179 >"$1/vendor"
    printf '%s\n' "$2" >"$1/device"
    ln -s "$1" "$FIXTURE/pci/${1##*/}"
}

mkdir -p "$FIXTURE/pci" "$FIXTURE/devices"
root1="$FIXTURE/devices/0001:01:00.0"
pci_device "$root1" 0x0623
for downstream in 0001:02:01.0 0001:02:02.0 0001:02:03.0; do
    pci_device "$root1/$downstream" 0x0623
done
pci_device "$root1/0001:02:03.0/0001:05:00.0" 0x0220
pci_device "$root1/0001:02:03.0/0001:05:00.1" 0x0220
ethv_qps615_collect_runtime "$FIXTURE/one-switch" "$FIXTURE/pci"
[ "$QPS615_SWITCH_COUNT" = 1 ]
[ "$QPS615_BRIDGE_COUNT" = 4 ]
[ "$QPS615_DOWNSTREAM_COUNT" = 5 ]
[ "$QPS615_ETHERNET_DEVICE_COUNT" = 2 ]
[ "$(wc -l <"$FIXTURE/one-switch/qps615_switches.log" | tr -d '[:space:]')" = 1 ]
printf '%s\n' 'PASS one switch with four bridge functions'

root2="$FIXTURE/devices/0002:01:00.0"
pci_device "$root2" 0x0623
pci_device "$root2/0002:02:01.0" 0x0623
ethv_qps615_collect_runtime "$FIXTURE/two-switches" "$FIXTURE/pci"
[ "$QPS615_SWITCH_COUNT" = 2 ]
[ "$QPS615_BRIDGE_COUNT" = 6 ]
[ "$QPS615_DOWNSTREAM_COUNT" = 6 ]
printf '%s\n' 'PASS independent switch roots'
