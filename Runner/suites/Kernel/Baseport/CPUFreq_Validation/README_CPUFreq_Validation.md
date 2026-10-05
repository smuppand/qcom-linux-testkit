# CPUFreq validation

`CPUFreq_Validation` validates CPU frequency policy topology, the advertised
frequency/OPP table, and functional transitions at every exposed frequency.
It uses only public CPUFreq sysfs interfaces and is portable across Yocto,
Debian, Ubuntu, and CentOS. The runner never installs packages.

## Coverage

For every `/sys/devices/system/cpu/cpufreq/policy*` directory, the suite:

- verifies that `related_cpus` or `affected_cpus` is populated;
- checks that each related CPU resolves to the same policy through its
  per-CPU `cpufreq` link;
- inventories the scaling driver, current governor, and CPU frequency range;
- validates all entries from `scaling_available_frequencies` and optional
  `scaling_boost_frequencies` against `cpuinfo_min_freq` and
  `cpuinfo_max_freq`;
- compares the policy frequency table with available `rate_hz` entries from
  the public OPP debugfs interface when the matching CPU OPP directory exists;
- falls back to the CPU minimum and maximum endpoints when a driver does not
  expose a discrete frequency table;
- clamps `scaling_min_freq` and `scaling_max_freq` to each advertised point;
- validates `scaling_cur_freq` or `cpuinfo_cur_freq` within a bounded wait and
  tolerance; and
- scans the captured kernel log for CPUFreq and OPP errors.

Before changing any policy, the runner snapshots its governor and scaling
limits. It restores all policies after each sweep, during final cleanup, and
when interrupted by HUP, INT, or TERM. It does not hotplug CPUs or alter
thermal trip points.

## Usage

```text
./run.sh [OPTIONS]

Options:
  --tolerance-khz <khz>  Maximum readback difference, 0-1000000 (default: 400)
  --settle-attempts <n>  One-second readback attempts, 1-30 (default: 5)
  -h, --help             Show help and exit
```

Examples:

```sh
./run.sh
./run.sh --tolerance-khz 1000 --settle-attempts 10
```

## Results

- `PASS`: policy topology and frequency tables are valid, every writable
  policy reaches all advertised frequencies, restoration succeeds, and no
  relevant kernel errors are found.
- `FAIL`: an applicable policy has malformed topology or frequency data,
  rejects an advertised point, cannot reach it within tolerance, reports a
  relevant kernel error, or cannot be restored.
- `SKIP`: CPUFreq is absent or one or more detected policies cannot run
  functional transitions because their controls are read-only. A missing
  discrete table uses endpoint fallback, and inaccessible kernel logs remain
  optional subchecks when all policies complete their functional sweep.

Malformed command-line arguments are reported as `FAIL`.

## Artifacts

Artifacts are retained under `logs_CPUFreq_Validation_<UTC timestamp>/`:

- `cpufreq_policy_snapshot.log`
- `cpufreq_policy_inventory.log`
- `policyN_frequencies.log`
- `policyN_opp_frequencies.log` and any `policyN_opp_mismatches.log`
- `cpufreq_frequency_results.csv`
- `dmesg_snapshot.log`, `dmesg_errors.log`, and kernel-log access evidence

## Public references

- [Linux CPU frequency and voltage scaling](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/pm/cpufreq.rst)
- [Linux OPP library](https://github.com/torvalds/linux/blob/master/Documentation/power/opp.rst)
