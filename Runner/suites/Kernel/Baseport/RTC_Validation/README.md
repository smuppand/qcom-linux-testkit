# RTC validation

`RTC_Validation` discovers Linux RTC class devices dynamically and validates
the selected RTC through the public Linux RTC ioctl interface. It does not use
SoC names, fixed bus addresses, or board-specific RTC mappings.

The existing `Timer` suite validates POSIX timers, while Ethernet
suspend/resume uses `rtcwake` only as a wake source. Neither provides focused
RTC device, time-progression, wake-alarm, or time-write validation, so this is
a separate suite.

## Default validation

The default run is read-only. It:

- records every `/sys/class/rtc/rtc*` device and matching `/dev/rtc*` node;
- selects the unique RTC marked `hctosys`, or the sole usable RTC;
- reads RTC time twice through `RTC_RD_TIME` and verifies progression; and
- captures RTC-related kernel health evidence with the shared dmesg helper.

If multiple usable RTCs exist without a unique `hctosys` device, select one
explicitly. If RTC hardware, a required image-provided utility, or an optional
capability is unavailable, the relevant validation skips cleanly.

```sh
cd Runner/suites/Kernel/Baseport/RTC_Validation
./run.sh
./run.sh --device /dev/rtc0
./run.sh --read-delay 3
```

## Wake-alarm validation

Wake-alarm validation is opt-in because it temporarily changes RTC alarm
state. It uses `RTC_WKALM_SET` and `RTC_WKALM_RD`, verifies the programmed
alarm, waits for an RTC alarm interrupt with a finite timeout, and restores the
original disabled alarm state. An already enabled or pending alarm is not
replaced.

```sh
./run.sh --alarm-test
./run.sh --device /dev/rtc1 --alarm-test --alarm-delay 10 --alarm-timeout 5
```

Unsupported alarm ioctls, an active pre-existing alarm, or insufficient target
permission produce `SKIP`. A programmed alarm that does not expire or report an
alarm event within the requested window produces `FAIL`.

## RTC time-set validation

`RTC_SET_TIME` validation changes persistent RTC time briefly and therefore
requires both an explicit test request and write authorization. The helper
snapshots the original RTC time, writes a small future offset, verifies
readback and progression, and restores the original timeline. It also attempts
restoration when interrupted.

```sh
./run.sh --time-set-test --allow-write
./run.sh --device /dev/rtc0 --time-set-test --allow-write \
    --time-set-offset 5 --read-delay 2
```

Do not enable this mode when another service is actively synchronizing or
managing the same hardware clock. Unsupported `RTC_SET_TIME` or missing
privilege produces `SKIP`. A write, readback, progression, or restoration
failure produces `FAIL`.

For `rtc-pm8xxx`, an `RTC_SET_TIME` result of `ENODEV` means target support is
not provisioned. The SKIP evidence reports whether the runtime DT provides
`allow-set-time`, an NVMEM cell named `offset`, or `qcom,uefi-rtc-info` for
persistent offset storage. The target needs direct time-setting permission or
one of those persistent offset mechanisms. This is an image or DT capability
gap and cannot be repaired by the test suite.

## Options and environment variables

| Command-line option | Environment variable | Default | Purpose |
|---|---|---:|---|
| `--device PATH` | `RTC_DEVICE` | `auto` | Select an RTC character device |
| `--read-delay SECONDS` | `RTC_READ_DELAY` | `2` | Delay between time reads |
| `--alarm-test` | `RTC_ALARM_ENABLE=1` | `0` | Enable wake-alarm validation |
| `--alarm-delay SECONDS` | `RTC_ALARM_DELAY` | `5` | Program the alarm this far ahead |
| `--alarm-timeout SECONDS` | `RTC_ALARM_TIMEOUT` | `3` | Allowed margin after the alarm time |
| `--time-set-test` | `RTC_TIME_SET_ENABLE=1` | `0` | Enable RTC time-set validation |
| `--time-set-offset SECONDS` | `RTC_TIME_SET_OFFSET` | `3` | Temporary future time offset |
| `--allow-write` | `RTC_ALLOW_WRITE=1` | `0` | Authorize the time write and restore |

CLI values override environment variables. The LAVA YAML enables alarm and
time-set validation with restoration so Yocto CI exercises the complete RTC
flow. An existing active alarm is never replaced, and unsupported time-setting
capability is reported as `SKIP` with target prerequisite evidence.

Environment examples:

```sh
RTC_DEVICE=/dev/rtc1 RTC_ALARM_ENABLE=1 ./run.sh
RTC_TIME_SET_ENABLE=1 RTC_ALLOW_WRITE=1 ./run.sh
```

## Results and artifacts

- `PASS`: an applicable operation completed and met its checks.
- `FAIL`: an operation started on an applicable RTC but failed validation, or
  target state could not be restored.
- `SKIP`: the RTC, optional ioctl capability, privilege, or requested execution
  environment is unavailable.

Evidence is retained under `results/RTC_Validation/run-*/`, including:

- `rtc_devices.tsv` for runtime device selection evidence;
- `rtc_read.tsv`, `rtc_alarm.tsv`, and `rtc_time_set.tsv` when applicable;
- helper stdout logs; and
- `kernel/dmesg_snapshot.log`, `kernel/dmesg_errors.log`, and
  `kernel/dmesg_access.log`.

The ioctl ABI follows the public Linux UAPI in
[`include/uapi/linux/rtc.h`](https://github.com/torvalds/linux/blob/master/include/uapi/linux/rtc.h).
The upstream Linux RTC selftest is useful reference coverage:
[`tools/testing/selftests/rtc/rtctest.c`](https://github.com/torvalds/linux/blob/master/tools/testing/selftests/rtc/rtctest.c).
