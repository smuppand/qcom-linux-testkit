# SOCCP remoteproc validation

`soccp_remoteproc` provides focused, read-only readiness validation for the
SOCCP remote processor. It complements the generic `remoteproc` suite, which
inventories every registered remote processor, by correlating SOCCP runtime
identity with the running device tree and checking SOCCP-specific readiness.

The suite uses no private kernel test module or debugfs control interface. It
does not trigger low-power transitions, remoteproc restarts, fatal errors, or
watchdog events.

## Run

```sh
cd Runner/suites/Kernel/Baseport/soccp_remoteproc
./run.sh
```

The suite:

- discovers SOCCP from runtime device-tree node names, `compatible`, or
  `firmware-name` properties and from remoteproc `name` or `firmware` values;
- stops immediately with `SKIP` when SOCCP is disabled or absent on the target;
- validates the bound driver and required remoteproc sysfs attributes when
  SOCCP is enabled;
- accepts `running`, `suspended`, and `attached` as ready states;
- validates whether the runtime-selected firmware is provisioned under the
  standard image firmware directories and records recovery and coredump
  evidence when exposed; and
- captures relevant kernel-health evidence without invoking `dmesg` directly.

No SoC name, remoteproc index, firmware path, SMP2P bit, or device-tree address
is fixed in the test.

## Options

```text
-h, --help    Show usage.
```

There are no target-specific environment variables or writable test modes.

## Result policy

- `PASS`: applicable SOCCP instances are bound, complete, and in `running`,
  `suspended`, or `attached` state, with no relevant kernel errors.
- `FAIL`: runtime DT enables SOCCP but no instance registers, or an applicable
  instance is unbound, incomplete, offline, detached, crashed, unexpected, or
  has relevant kernel errors.
- `SKIP`: SOCCP is disabled or absent, matching runtime DT identity is not
  visible despite authoritative sysfs evidence, the runtime-selected firmware
  file is not exposed under the standard image firmware directories, or
  kernel-log access is unavailable. A running, suspended, or attached instance
  remains authoritative evidence that SOCCP is active, so a missing visible
  firmware file is reported as an actionable optional-evidence skip rather than
  a false runtime failure. Optional evidence skips do not override successful
  applicable checks, so the overall suite may pass with a nonzero skipped
  count.

## Artifacts

Each applicable run stores evidence under `results/soccp_remoteproc/run-*/`,
including:

- `soccp_dt_nodes.log`
- `remoteproc_inventory.tsv`
- `soccp_remoteproc.tsv`
- `kernel/dmesg_snapshot.log`
- `kernel/dmesg_errors.log`
- `kernel/dmesg_access.log`

The LAVA result remains `soccp_remoteproc.res` in the suite directory.

Public interface references:

- [Linux remoteproc API](https://github.com/torvalds/linux/blob/master/include/linux/remoteproc.h)
- [Linux remoteproc sysfs](https://github.com/torvalds/linux/blob/master/drivers/remoteproc/remoteproc_sysfs.c)
