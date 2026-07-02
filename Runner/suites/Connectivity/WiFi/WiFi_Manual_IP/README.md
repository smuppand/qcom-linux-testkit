# WiFi Manual IP

## Overview

`WiFi_Manual_IP` validates WiFi connectivity using `wpa_supplicant` and manual DHCP invocation through `udhcpc`.

The test connects to the configured SSID, requests an IP address using `udhcpc`, and verifies internet connectivity with `ping`.

## What the test validates

- WiFi credentials are available through CLI arguments, environment, or the repo WiFi credential helper.
- Required tools are present.
- A WiFi interface is detected.
- A valid `udhcpc` script is available or generated.
- `wpa_supplicant` can associate with the configured access point.
- `udhcpc` assigns an IP address.
- Internet connectivity is verified by pinging `8.8.8.8`.

## Dependencies

The target should provide:

- `iw`
- `wpa_supplicant`
- `udhcpc`
- `ip`
- `ping`

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
$REPO_PATH/Runner/utils/send-to-lava.sh WiFi_Manual_IP.res
```

## Output files

The test may create these temporary or diagnostic files in the test directory or `/tmp`:

```text
wpa.log
/tmp/wpa_supplicant.conf
```

The script installs an exit trap to restore the `udhcpc` script state through the common helper.

## PASS criteria

The test passes when:

1. A WiFi interface is found.
2. A WPA configuration is generated successfully.
3. `wpa_supplicant` starts successfully for the interface.
4. `udhcpc` assigns an IP address.
5. Ping to `8.8.8.8` succeeds.

## SKIP criteria

The test skips when SSID or password is missing.

## FAIL criteria

The test fails when:

- Required dependencies are missing.
- No WiFi interface is detected.
- `udhcpc` script setup fails.
- WPA configuration generation fails.
- IP assignment fails.
- Ping fails after IP assignment.

## Notes

- This test is focused on the `wpa_supplicant` + `udhcpc` path.
- For automatic connection fallback using both `nmcli` and `wpa_supplicant`, use `WiFi_Dynamic_IP`.
- The password is hidden in logs.
