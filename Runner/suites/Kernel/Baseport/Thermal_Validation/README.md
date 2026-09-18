# Thermal validation

`Thermal_Validation` exposes the existing device-tree thermal readiness check
as a focused suite and adds runtime trip-point and cooling-binding evidence.
The default path is read-only and portable across supported distributions.
Optional thermal ABI attributes remain informational when the kernel does not
expose them, and a cooling binding value of `-1` is accepted as unassociated.

Thermal zones, trip points, bindings, sensors, and cooling devices are all
discovered from runtime DT and sysfs. Users do not supply a SoC-specific zone or
sensor list. This keeps the readiness path portable when different targets
expose different thermal policies.

## Optional controlled load

The load phase is disabled by default for direct `run.sh` execution and uses
only an image-provided `stress-ng`. The LAVA YAML enables it by default through
`THERMAL_LOAD_ENABLE=1`, because selecting this focused functional suite is the
CI opt-in to the bounded load. It checks that telemetry remains readable once
per second, records the maximum observed temperature rise and cooling-device
state increase, and samples again after a recovery interval. A small
temperature rise or no cooling-state increase is reported as a subcheck
`SKIP`, because workload placement, cooling, trip thresholds, and sensor
cadence vary by target. Command failure or lost final telemetry is a failure.

`--load-enable 1` is an operator or CI policy, not an automatically inferred
capability. Enable it only where a bounded CPU load is acceptable. The duration,
worker count, recovery delay, and minimum-rise threshold tune that optional
phase; they do not describe the SoC thermal topology.

There is intentionally no shell busy-loop fallback. `stress-ng` supplies a
bounded, auditable worker lifecycle and exit status, while an ad hoc loop can
distort scheduling, evade reliable cleanup, or provide misleading load proof.
Images without `stress-ng` retain full read-only thermal readiness coverage and
skip only the optional controlled-load subcheck.

```sh
./run.sh
./run.sh --load-enable 1 --load-seconds 20 --load-workers 2
```

| Option | Environment | `run.sh` default | YAML default |
|---|---|---:|---:|
| `--load-enable` | `THERMAL_LOAD_ENABLE` | `0` | `1` |
| `--load-seconds` | `THERMAL_LOAD_SECONDS` | `15` | `15` |
| `--load-workers` | `THERMAL_LOAD_WORKERS` | `1` | `1` |
| `--recovery-seconds` | `THERMAL_RECOVERY_SECONDS` | `5` | `5` |
| `--min-rise-mc` | `THERMAL_MIN_RISE_MC` | `1000` | `1000` |

## Logs and results

Look for `[THERMAL-SELECTION]`, `[THERMAL]`, `[THERMAL-POLICY]`,
`[THERMAL-TRIP]`, `[THERMAL-BINDING]`, `[THERMAL-LOAD]`, and
`[THERMAL-SAMPLE]`. Trip and binding details are printed up to 64 rows, followed
by an omitted count and artifact path for larger policies. Load samples are
summarized by phase with sensor counts, minimum and maximum temperatures,
hottest zone, and maximum cooling state rather than dumping every sample.
The generated `thermal_samples.tsv.summary.tsv` is retained, and summary parser
failure is reported as a test failure instead of being hidden by a shell
pipeline.
`[THERMAL-SELECTION]` records dynamic capability discovery and
whether the optional load policy was enabled. The printed
`results/Thermal_Validation/run-*/` directory retains zone, cooling, policy,
load, sample, and kernel evidence.

- `PASS`: declared thermal runtime is valid and enabled phases complete.
- `FAIL`: declared zones or cooling devices are missing/malformed, load
  execution fails, telemetry disappears, or relevant kernel errors are found.
- `SKIP`: thermal capability is absent or an optional load/tool/log is absent.

Kernel health capture prefers `dmesg` and falls back to image-provided
`journalctl -k`. `kernel/dmesg_access.log` retains the provider and exact access
diagnostics when neither source is readable.
