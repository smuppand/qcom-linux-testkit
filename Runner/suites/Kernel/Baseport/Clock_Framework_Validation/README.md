# Common Clock Framework validation

`Clock_Framework_Validation` validates the complete portable Linux clock
workflow. It covers Common Clock Framework state, hierarchy and consumers,
driver-core sync-state evidence, and the existing focused CPUFreq policy/OPP
and frequency-transition suite. It is portable across Yocto, Debian, Ubuntu,
and CentOS images and does not contain SoC clock lists, register addresses,
private payload paths, or distribution-specific behavior.

The supplied legacy test is Qualcomm proprietary and cannot be copied into
this public repository. It also depends on writable downstream debugfs clock
nodes and extensive SoC-specific blacklists. Upstream Linux deliberately keeps
generic Common Clock Framework debugfs controls read-only because arbitrary
clock rate and enable changes can destabilize the system. This suite exercises
all functional areas through public runtime interfaces: generic clocks are
validated through framework state and real consumer activity, while controlled
rate transitions use CPUFreq policy interfaces that define safe limits and
restoration semantics.

This provides portable functional equivalents for the supplied `run.sh`,
`clk_test.sh`, `sync_state.sh`, and `cpufreq_hw_test.sh` workflows without
copying proprietary code or importing unsafe platform blacklists.

## Scope

The suite:

- discovers an existing debugfs mount from the runtime mount table;
- temporarily mounts debugfs at the standard kernel mountpoint only when no
  debugfs mount already exists, then restores that state;
- discovers `clk_summary` beneath the active debugfs root;
- inventories enabled device-tree clock providers through `#clock-cells`;
- captures and validates multiple bounded `clk_summary` snapshots;
- records clock count, enabled state, prepare state, protection state, rate,
  and hardware-enable metrics when those columns are available;
- reconstructs and validates the runtime parent-child clock hierarchy;
- inventories registered clock consumers and connection identifiers from
  modern `clk_summary` output;
- correlates DT clock providers with bound platform devices and dynamically
  inventories their `consumer*/status` sync-state entries;
- records clock state or rate changes observed between passive samples;
- invokes `CPUFreq_Validation` with a finite timeout to validate CPU policy
  topology, OPP frequencies, every advertised frequency transition, and
  restoration of the original governor and limits;
- retains optional `clk_dump` and orphan-clock diagnostics when exposed; and
- uses the shared kernel-log scanner for clock-controller errors.

The runner prints each operation to stdout with a `[CLOCK-OP]` tag. It also
prints every sample's metrics, a bounded clock-state view, and bounded state
deltas. When output is truncated, the stdout message reports the omitted line
count and identifies the complete retained artifact. Clock-state rows use
`name|enable_count|prepare_count|protect_count|rate_hz|hardware_enabled`.

All clock names, providers, consumers, policy domains, and frequency points
come from the running kernel. The suite does not maintain platform mappings or
write generic clock debugfs controls. CPUFreq behavior remains implemented in
the focused `Runner/suites/Kernel/Baseport/CPUFreq_Validation` suite and is
orchestrated here instead of duplicating that logic.

## Prerequisites

- An image-provided POSIX shell and base utilities.
- Linux Common Clock Framework support.
- An accessible debugfs filesystem with `clk_summary` for generic Common Clock
  Framework state and hierarchy validation.
- Root privileges when debugfs is not already mounted and that subcheck is
  expected to run.
- Root privileges for functional CPUFreq transitions when CPUFreq policies
  are present and writable validation is expected.

The runner never installs packages. Missing optional image capabilities are
reported as `SKIP` with the required image or kernel prerequisite, and the
independent sync-state and CPUFreq workflows continue when debugfs is absent.

## Usage

```text
./run.sh [OPTIONS]

Options:
  --samples <count>    Number of clk_summary snapshots, 1-60 (default: 3)
  --interval <seconds> Delay between snapshots, 0-60 (default: 1)
  --cpufreq-timeout <seconds>
                       CPUFreq validation timeout, 60-7200 (default: 1800)
  -h, --help           Show help and exit
```

Examples:

```sh
./run.sh
./run.sh --samples 5 --interval 2
./run.sh --samples 1 --cpufreq-timeout 3600
```

The default run takes three snapshots one second apart. Sampling is passive,
so a system with no clock activity during the observation window can still
pass structural validation while reporting the transition subcheck as `SKIP`.

## Results

- `PASS`: `clk_summary` is readable, every requested snapshot and hierarchy is
  valid, applicable consumer and sync-state information is inventoried, the
  focused CPUFreq suite passes when policies are present, and clock-related
  kernel logs are clean when accessible.
- `FAIL`: an exposed clock summary cannot be read or parsed, a bounded capture
  fails, hierarchy invariants fail, sync-state inventory generation fails, an
  applicable CPUFreq policy/OPP/transition check fails or times out,
  clock-related kernel errors are detected, or modified runtime state cannot
  be restored.
- `SKIP`: the image does not expose the optional debugfs clock diagnostics,
  consumer connection fields, driver-core sync-state status, CPUFreq policies,
  writable CPUFreq controls, required image-provided base utilities, or kernel
  logs. No passive transition during the sample window is also a skipped
  observation. An optional skipped subcheck does not override completed PASS
  coverage.

Malformed command-line arguments are reported as `FAIL`.

## Artifacts

Artifacts are retained under
`logs_Clock_Framework_Validation_<UTC timestamp>/`:

- `clock_providers.log`
- `clk_summary_NNN.log`
- `clk_state_NNN.log`
- `clk_metrics_NNN.csv`
- `clk_delta_NNN.log` when state changes are observed
- `clock_transitions.log`
- `clock_topology.log` and `clock_topology_metrics.csv`
- `clock_consumers.log`
- `clock_sync_state.log` and `clock_sync_state_metrics.csv`
- `cpufreq_validation.log` and the copied `CPUFreq_Validation.res`
- `legacy_workflow_coverage.csv`, mapping every supplied legacy workflow to
  its portable implementation and runtime result
- optional `clk_dump.log`, `clk_orphan_summary.log`, and
  `clk_orphan_dump.log`
- `dmesg_snapshot.log`, `dmesg_errors.log`, and kernel-log access evidence

## Public references

- [Linux Common Clock Framework documentation](https://github.com/torvalds/linux/blob/master/Documentation/driver-api/clk.rst)
- [Linux Common Clock Framework debugfs implementation](https://github.com/torvalds/linux/blob/master/drivers/clk/clk.c)
- [Linux debugfs documentation](https://github.com/torvalds/linux/blob/master/Documentation/filesystems/debugfs.rst)
- [Linux CPU frequency and voltage scaling](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/pm/cpufreq.rst)
