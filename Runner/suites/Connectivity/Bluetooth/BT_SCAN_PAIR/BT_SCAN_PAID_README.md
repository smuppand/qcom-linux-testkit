# Bluetooth Scan and Pair Test

## Test Name
`BT_SCAN_PAIR`

## Description
This script validates Bluetooth functionality on a target device by:
- Ensuring the Bluetooth controller (`hci0`) is available and powered on
- Scanning for available Bluetooth devices
- Matching and pairing with a specified expected device

## Prerequisites
- `bluetoothctl`
- `rfkill`
- `hciconfig`
- `expect`

## Input
You can provide the expected device via:
- First command-line argument
- `BT_NAME_ENV` environment variable
- `bt_device_list.txt` (1st line)

Example `bt_device_list.txt`:
```
QCOM-BTD
```

## Cleanup
The script will:
- Unpair the expected device after test (to keep CI clean)
- Kill background `bluetoothctl`
