#!/bin/sh
 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
 
# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="BT_SCAN_PAIR"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}
 
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

BT_NAME=""
BT_MAC=""

# Get expected BT name
if [ -n "$1" ]; then
    BT_NAME="$1"
elif [ -n "$BT_NAME_ENV" ]; then
    BT_NAME="$BT_NAME_ENV"
elif [ -f "./bt_device_list.txt" ]; then
    BT_NAME=$(awk 'NR==1 {print $1}' ./bt_device_list.txt)
fi

check_dependencies bluetoothctl rfkill expect hciconfig || {
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

cleanup_bt() {
    log_info "Cleaning up previous Bluetooth state..."
    bluetoothctl power on >/dev/null 2>&1
    if [ -n "$BT_MAC" ]; then
        bluetoothctl remove "$BT_MAC" >/dev/null 2>&1
        log_info "Unpaired device: $BT_MAC"
    fi
    killall -q bluetoothctl 2>/dev/null
}

retry() {
    cmd="$1"
    desc="$2"
    max=3
    count=1
    while [ "$count" -le "$max" ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Retry $count/$max failed: $desc"
        count=$((count + 1))
        sleep 2
    done
    return 1
}

log_info "Unblocking and powering on Bluetooth"
rfkill unblock bluetooth
retry "hciconfig hci0 up" "Bring up hci0" || {
    log_fail "Failed to bring up hci0"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

cleanup_bt

log_info "Scanning for Bluetooth devices..."
retry "bluetoothctl --timeout 10 scan on > scan.log 2>&1 & sleep 12; killall -q bluetoothctl" "Bluetooth scanning" || {
    log_fail "Device scan failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
}

DEVICES=$(grep -i 'Device' scan.log | sort | uniq)
echo "$DEVICES" > found_devices.log
log_info "Devices found during scan:
$DEVICES"

# If no expected device, consider scan pass
if [ -z "$BT_NAME" ]; then
    log_pass "No expected device specified. Scan only."
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
fi

if echo "$DEVICES" | grep -i "$BT_NAME" >/dev/null; then
    log_info "Expected device '$BT_NAME' found in scan"
    BT_MAC=$(grep -i "$BT_NAME" scan.log | awk '{print $3}' | head -n1)
else
    log_fail "Expected device '$BT_NAME' not found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if [ -z "$BT_MAC" ]; then
    log_fail "MAC address not found for device '$BT_NAME'"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Attempting to pair with $BT_NAME ($BT_MAC)"

expect <<EOF > pair.log 2>&1
spawn bluetoothctl
expect "#"
send "agent on\r"
expect "#"
send "default-agent\r"
expect "#"
send "pair $BT_MAC\r"
expect {
    "Pairing successful" {
        exit 0
    }
    "Failed to pair: org.bluez.Error.AlreadyExists" {
        send "remove $BT_MAC\r"
        expect "#"
        send "pair $BT_MAC\r"
        expect {
            "Pairing successful" { exit 0 }
            timeout { exit 1 }
        }
    }
    timeout {
        exit 1
    }
}
EOF

if grep -q "Pairing successful" pair.log; then
    log_pass "Pairing successful with $BT_MAC"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "Pairing failed with $BT_MAC"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

cleanup_bt
log_info "Completed $TESTNAME Testcase"
