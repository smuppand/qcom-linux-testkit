# WiFi On/Off

## Overview

`WiFi_OnOff` validates WiFi runtime readiness and verifies that the detected WiFi interface can be toggled down and back up.

The test performs kernel configuration checks, device tree visibility checks, module visibility logging, probe/runtime failure checks, interface detection, and interface up/down validation.

## What the test validates

- Required tools are present.
- Mandatory WiFi kernel configs are enabled.
- Optional WiFi configs are reported when visible.
- WiFi or combined WCN device tree entries are visible based on configured patterns.
- WiFi driver module visibility and recognized-platform driver bindings are
  logged.
- Target-specific WiFi driver kernel configs can be inferred and validated.
- Kernel logs do not show WiFi probe/runtime failures.
- A usable WiFi interface appears within the configured wait window.
- The WiFi interface can be brought down and back up.

## Dependencies

The target should provide:

- `ip`
- `iw`

The script sources the common test environment through `init_env`, then uses helpers from:

- `functestlib.sh`
- `lib_connectivity.sh`

## Usage

Run from the test directory:

```sh
./run.sh
```

Run with common overrides:

```sh
WIFI_WAIT_SECS=90 WIFI_WAIT_STEP_SECS=3 WIFI_RECOVERY_RELOAD=1 ./run.sh
```

Run with a preferred interface override:

```sh
WIFI_IFACE=wlan0 ./run.sh
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `WIFI_WAIT_SECS` | `60` | Maximum time to wait for a WiFi interface |
| `WIFI_WAIT_STEP_SECS` | `2` | Poll interval while waiting for the interface |
| `WIFI_RECOVERY_RELOAD` | `1` | Enable best-effort recovery reload behavior |
| `WIFI_RECOVERY_RELOAD_AFTER_S` | empty / auto | Time before recovery reload is attempted |
| `WIFI_PROBE_LOG_DIR` | `./wifi_onoff_dmesg` | Directory used for WiFi probe/runtime log evidence |
| `WIFI_PROBE_LOG_TAG` | `WiFi_OnOff/probe` | Log tag used when reporting probe checks |
| `WIFI_IFACE` | empty | Optional interface override |
| `WIFI_DT_PATTERNS` | built-in list | Newline-separated DT compatible/name patterns |
| `WIFI_DRIVER_MODULES` | built-in list | Newline-separated driver module names to log/check |

Default DT patterns include Qualcomm/WCN and common WiFi identifiers such as `qcom,wcn7850`, `qcom,wcn6855`, `ath12k`, `ath11k`, `ath10k`, `wifi`, `wlan`, and `qca`. PCIe M.2 WiFi coverage also includes `qcom,pcie-m2-1418-lga-connector` and `pcie-m2-e-connector`.

Default module names include the ath12k, ath11k, and ath10k core and transport modules, `cfg80211`, `mac80211`, `mhi`, and the PCIe M.2 support module `pwrseq_pcie_m2`.

Arduino VENTUNO Q is identified from its runtime `arduino,monza` compatible.
On that platform the test requires the QCA2066 connector compatibles
`qcom,pcie-m2-1418-lga-connector` and `pcie-m2-e-connector`, then validates
`pwrseq_pcie_m2`, `ath11k`, and `ath11k_pci`. The platform and PCI drivers must
also have bound runtime devices. Missing DT or driver binding evidence is a
platform failure rather than an optional-hardware skip.

The Ventuno Q DT and driver-binding prerequisites are checked before the
interface wait or recovery path. A missing connector node or unbound mandatory
driver therefore fails immediately instead of waiting for an interface that
cannot be created or reloading an unbound module.

## LAVA usage

The YAML exposes these parameters:

```yaml
params:
  WIFI_WAIT_SECS: "60"
  WIFI_WAIT_STEP_SECS: "2"
  WIFI_RECOVERY_RELOAD: "1"
  WIFI_RECOVERY_RELOAD_AFTER_S: ""
```

The LAVA step runs:

```sh
WIFI_WAIT_SECS="${WIFI_WAIT_SECS}" WIFI_WAIT_STEP_SECS="${WIFI_WAIT_STEP_SECS}" WIFI_RECOVERY_RELOAD="${WIFI_RECOVERY_RELOAD}" WIFI_RECOVERY_RELOAD_AFTER_S="${WIFI_RECOVERY_RELOAD_AFTER_S}" ./run.sh || true
```

The final test result is emitted through:

```sh
$REPO_PATH/Runner/utils/send-to-lava.sh WiFi_OnOff.res
```

## Output files

The test writes standard test result output through the common result helper. Probe/runtime diagnostics may be collected under:

```text
wifi_onoff_dmesg/
```

The directory can be changed with `WIFI_PROBE_LOG_DIR`.

## PASS criteria

The test passes when:

1. Mandatory WiFi kernel configs are enabled.
2. No WiFi probe/runtime failures are detected.
3. A WiFi interface is detected.
4. The interface can be brought down.
5. The interface can be brought back up.

## SKIP criteria

The test skips when no usable WiFi interface or runtime WiFi object is found and no probe/runtime failure is detected.

## FAIL criteria

The test fails when:

- Mandatory WiFi kernel configs are missing.
- Target-specific WiFi driver kernel configs are missing.
- WiFi probe/runtime failures are detected.
- The WiFi runtime stack is present but no usable interface appears.
- A recognized platform is missing its required WiFi DT compatible, kernel
  driver stack, or bound runtime devices.
- The interface cannot be brought down.
- The interface cannot be brought back up.

## Notes

- This test does not connect to an access point.
- Use `WiFi_Dynamic_IP` or `WiFi_Manual_IP` to validate association, DHCP, and external connectivity.
- The test logs extra diagnostics when no interface appears or an interface
  toggle operation fails, including bound driver devices and Qualcomm or
  network-class PCI inventory for recognized platforms.
