# Cache irritators

`Cache_Irritators` exercises CPU cache traffic and, when supported by the
installed tool, TLB shootdowns using an image-provided `stress-ng` binary. It
is intended for direct use on Yocto, Debian, Ubuntu, and CentOS targets.

The source supplied for the original test is marked for internal use only and
not for distribution. It also uses an ARM64 kernel module to issue privileged
EL1 cache and TLB maintenance instructions. None of that restricted source is
included or translated here. This suite is a public userspace replacement based
on the stressors exposed by [stress-ng](https://github.com/ColinIanKing/stress-ng).

The userspace replacement creates cache pressure over the complete detected
cache topology and separately targets each runtime-discovered L1, L2, and L3
level when `stress-ng` supports `--cache-level`. It also requests real
kernel-mediated TLB shootdowns through mapping and protection changes.

It does not claim to reproduce direct set/way cache maintenance. ARM64 cache
set/way operations and direct TLBI instructions execute at EL1 and cannot be
issued by a portable userspace test. Adding a runtime-built out-of-tree module
would require matching kernel headers and toolchains on every target and would
not be portable across the supported distributions.

## Prerequisites and package policy

- Yocto and other image-managed systems must provide `stress-ng` in the image.
  The runner never invokes `opkg` or another package manager on these systems.
- Debian and Ubuntu recover the `stress-ng` package with `apt` when it is
  missing.
- CentOS recovers the `stress-ng` package with `dnf` or `yum` when it is
  missing.

The package manager resolves the runtime dependencies of `stress-ng` in the
same transaction. Package recovery uses the shared repository provider and the
`cache-irritators` mappings in `Runner/config/pkg_command_map.conf`. No source
is downloaded or compiled by this suite.

Package recovery failure on Debian, Ubuntu, or CentOS is reported as `FAIL`.
An image-managed or unsupported OS without `stress-ng` reports `SKIP` with the
image prerequisite.

The runner detects support from `stress-ng --help` instead of using distro or
package-version gates:

- `--cache` and `--cache-ops` are required for the primary workload.
- `--cache-level` enables separate runtime-discovered L1, L2, and L3 workloads.
- `--tlb-shootdown` and `--tlb-shootdown-ops` are optional. Their subcheck is
  reported as `SKIP` when the installed build does not provide them.
- Automatic cache tuning uses `--cache-enable-all` when advertised, matching
  the recommendation emitted by the tested CentOS stress-ng 0.19.03 build.
- Explicit cache tuning options, `--verify`, `--metrics-brief`, and the
  stress-ng internal `--timeout` are used only when advertised.

An outer managed watchdog always bounds each stressor.

## Usage

```text
./run.sh [--nominal | --repeatability | --stress | --mode <mode>] [OPTIONS]

Modes:
  -n, --nominal          Run one operation unit per available workload (default)
  -r, --repeatability    Run ten operation units per available workload
  -s, --stress           Run one hundred operation units per available workload

Options:
  --workers <count>      stress-ng workers per supported stressor (default: 1)
  --operations <count>   Override mode operation units (default: auto)
  --timeout <seconds>    Maximum time per stressor (default: 120)
  --cache-options <csv>  Cache flags: auto, none, enable-all, fence, flush,
                         no-affinity, permute, prefetch (default: auto)
  --cache-size <size>    Override stress-ng cache size, for example 4M
  --cache-ways <count>   Limit the cache ways exercised
  -h, --help             Show help and exit
```

Examples:

```sh
./run.sh
./run.sh --repeatability
./run.sh --stress --workers 2 --timeout 300
./run.sh --mode nominal --cache-options prefetch,permute
./run.sh --operations 25 --cache-size 4M --cache-ways 4
```

Only one mode may be selected. Worker and timeout values must be positive
integers. `--operations` overrides the operation count selected by the mode.

Custom cache flags are deliberately limited to cache-specific, non-destructive
stress-ng options. The runner rejects unknown options and fails when an
explicitly requested option is not advertised by the installed binary. Use
`--cache-options none` to disable automatic cache tuning.

## Yocto CI

`Cache_Irritators.yaml` exposes the safe runner controls as LAVA parameters.
Its default nominal run assumes `stress-ng` is already present in the Yocto
image. The YAML does not enable package recovery.

| YAML parameter | Runner option | Default |
| --- | --- | --- |
| `MODE` | `--mode` | `nominal` |
| `WORKERS` | `--workers` | `1` |
| `OPERATIONS` | `--operations` | `auto` |
| `TIMEOUT` | `--timeout` | `120` |
| `CACHE_OPTIONS` | `--cache-options` | `auto` |
| `CACHE_SIZE` | `--cache-size` | `auto` |
| `CACHE_WAYS` | `--cache-ways` | `auto` |

## Results

- `PASS`: an applicable stressor completed successfully, and no executed check
  failed.
- `FAIL`: an advertised stressor failed, timed out, reported an incomplete
  workload, or relevant kernel errors were captured.
- `SKIP`: an image-managed target lacks `stress-ng`, the required cache
  stressor is unavailable, an optional TLB stressor is unavailable, or
  kernel-log access is unavailable. A skipped optional subcheck does not
  override a successful cache workload.

Artifacts are retained in `logs_Cache_Irritators_<UTC timestamp>/` and include
the stress-ng version and capability output, per-stressor logs, and the shared
kernel-log scan files.
