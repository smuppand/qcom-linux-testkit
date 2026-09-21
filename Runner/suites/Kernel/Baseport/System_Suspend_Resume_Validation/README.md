# System suspend/resume validation

`System_Suspend_Resume_Validation` is an opt-in, generic system health test. It
uses an RTC alarm to enter suspend, verifies that the target resumed instead of
rebooting, and waits for every pre-suspend platform, PCI, I2C, SPI, auxiliary,
USB, MMC, and AMBA device/driver binding to return. Remote processor states are
also compared with their pre-suspend snapshot.

The device set is discovered from the running system, so no SoC-specific list
of controllers or drivers is maintained. The suite snapshots whatever is bound
before suspend and requires that same runtime state to recover afterward.

## Safety and transaction rules

The default is disabled. Enable the suite only when an independent serial or
LAVA recovery channel is available. The suite refuses to overwrite an existing
RTC alarm. It prefers the image-provided `rtcwake`. When that utility is absent,
it arms a relative alarm through `/sys/class/rtc/rtcX/wakealarm`, verifies the
alarm, and writes the selected mode to `/sys/power/state`. Both paths use the
same watchdog and cleanup. If the test-owned alarm remains armed, the suite
clears it and verifies cleanup. It does not stop services, alter persistent
boot settings, or change device configuration.

`--enable 1` cannot be inferred safely from hardware. It is an operator or CI
policy confirming that the job has an independent recovery channel. The RTC is
otherwise selected automatically from devices exposing a readable and writable
wake alarm. An explicitly disabled kernel wakeup state rejects a candidate,
while an unreported state remains eligible for RTC drivers that omit it.
Use `--rtc-device` only when a lab or platform policy requires a particular
wake-capable RTC. The requested suspend mode is validated against
`/sys/power/state`, so unsupported modes skip cleanly.
An explicitly requested RTC that is absent, inaccessible, wake-disabled, or
lacks a usable wake alarm fails because the operator supplied a strict policy.

## Run

```sh
./run.sh --enable 1
./run.sh --enable 1 --suspend-seconds 20 --suspend-mode mem
```

CLI options override the matching environment variables:

| Option | Environment | Default | Purpose |
|---|---|---:|---|
| `--enable` | `SYSTEM_SUSPEND_ENABLE` | `0` | Explicit safety opt-in |
| `--suspend-seconds` | `SYSTEM_SUSPEND_SECONDS` | `30` | RTC wake interval |
| `--suspend-mode` | `SYSTEM_SUSPEND_MODE` | `mem` | Mode exposed by `/sys/power/state` |
| `--rtc-device` | `SYSTEM_RTC_DEVICE` | automatic | RTC character device |
| `--resume-timeout` | `SYSTEM_RESUME_TIMEOUT` | `30` | Shared device and remoteproc recovery budget |

## Validation and artifacts

The suite logs `[SUSPEND-POLICY]`, `[SUSPEND-RTC-CANDIDATE]`,
`[SUSPEND-DISCOVERY]`, `[SUSPEND-SAFETY]`, `[SUSPEND-SNAPSHOT]`,
`[SUSPEND-ACTION]`, `[SUSPEND-RESTORE]`, `[SUSPEND-DEVICES]`,
`[SUSPEND-REMOTEPROC-*]`, and `[SUSPEND-WAKE-*]`. RTC candidates include
eligibility or rejection evidence. Boot ID, uptime, remoteproc state, missing
bindings, and bounded wake-source snapshots are printed directly, with full
artifacts retained. `[SUSPEND-POLICY]` identifies automatic versus overridden RTC
selection and records the explicit safety opt-in. The printed
`results/System_Suspend_Resume_Validation/run-*/` directory retains the
provider transcript, alarm setup evidence, before/after binding snapshots, missing bindings,
wake-source snapshots, remoteproc states, boot IDs, uptime records, and kernel
logs.

- `PASS`: suspend returns after the expected bounded interval, boot identity is
  unchanged, bindings and remote processors recover, RTC alarm state is clean,
  and no relevant kernel errors are found.
- `FAIL`: an explicit RTC selection is unusable, suspend fails or times out,
  the board reboots, a binding is lost, cleanup fails, or kernel errors are
  detected.
- `SKIP`: not explicitly enabled, required privilege/mode/RTC is absent, both
  suspend providers are unavailable,
  a pre-existing RTC alarm makes the operation unsafe, or optional logs are
  inaccessible.

Kernel health capture prefers `dmesg` and falls back to image-provided
`journalctl -k`; `kernel/dmesg_access.log` retains provider and permission
diagnostics.
