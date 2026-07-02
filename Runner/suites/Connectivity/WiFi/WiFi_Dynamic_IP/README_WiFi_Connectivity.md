# WiFi Dynamic IP

## Overview

`WiFi_Dynamic_IP` validates WiFi connectivity using DHCP-based IP assignment. The test connects to an access point, verifies that the WiFi interface receives an IP address, and confirms external connectivity using `ping`.

The test first attempts connection through `nmcli`. If that path does not complete successfully, it falls back to `wpa_supplicant` with `udhcpc`.

## What the test validates

- WiFi credentials are available through CLI arguments, environment, or the repo WiFi credential helper.
- Required tools are present.
- `systemd-networkd.service` is available where applicable.
- A WiFi interface is detected.
- The device can connect to the configured SSID.
- DHCP assigns an IP address to the WiFi interface.
- Internet connectivity is verified by pinging `8.8.8.8`.

## Dependencies

The target should provide:

- `iw`
- `ping`
- `nmcli` for the primary connection path
- `wpa_supplicant` and `udhcpc` for fallback connection
- `systemd-networkd.service` on systemd-based images

The script sources the common test environment through `init_env` and uses common helpers from `functestlib.sh`.

## Usage

Run from the test directory:

```sh
./run.sh --ssid "<SSID>" --password "<PASSWORD>"
```

Show help:

```sh
./run.sh --help
```

The script supports these arguments:

| Argument | Description |
|---|---|
| `--ssid <SSID>` | WiFi access point SSID |
| `--password <PASSWORD>` | WiFi access point password |
| `--help`, `-h` | Print usage and exit |

## LAVA usage

The YAML exposes the WiFi credentials as parameters:

```yaml
params:
  SSID: ""
  PASSWORD: ""
```

The LAVA step runs:

```sh
./run.sh --ssid "${SSID}" --password "${PASSWORD}" || true
```

The final test result is emitted through:

```sh
$REPO_PATH/Runner/utils/send-to-lava.sh WiFi_Dynamic_IP.res
```

## Output files

The test writes a ping log in the test directory:

```text
wifi_ping_<interface>.log
```

This log contains the ping output from the connectivity check. It is useful when the test connects successfully but the external connectivity check fails.

## PASS criteria

The test passes when:

1. A WiFi interface is found.
2. The target connects to the configured SSID using either `nmcli` or `wpa_supplicant`.
3. The WiFi interface receives an IP address.
4. Ping to `8.8.8.8` succeeds.

## SKIP criteria

The test skips when SSID or password is missing.

## FAIL criteria

The test fails when:

- Required dependencies are missing.
- Network service validation fails.
- No WiFi interface is detected.
- Both connection methods fail.
- IP assignment fails after connection.
- Ping fails after IP assignment.

## Notes

- The password is hidden in logs.
- The test performs cleanup through WiFi helper functions before exit.
- The fallback path helps support minimal images where `nmcli` may not be sufficient or available.
