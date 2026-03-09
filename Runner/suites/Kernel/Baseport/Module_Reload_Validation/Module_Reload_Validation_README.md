# Module_Reload_Validation

## Overview
`Module_Reload_Validation` is a generic, profile-driven kernel module unload/reload regression suite.

It is intended to catch issues such as:
- module unload hangs,
- failed reloads,
- service/device rebind regressions after reload,
- issues that reproduce on the 1st, 2nd, or later reload iteration.

The suite uses:
- a **generic engine** in `run.sh`,
- shared helper logic in `Runner/utils/lib_module_reload.sh`,
- **module-specific profiles** under `profiles/`.

## Folder layout

```text
Runner/suites/Kernel/Baseport/Module_Reload_Validation/
├── run.sh
├── Module_Reload_Validation.yaml
├── profiles/
│   ├── enabled.list
│   └── fastrpc.profile

Runner/utils/
└── lib_module_reload.sh
```

## Main components

### `run.sh`
Thin orchestration layer that:
- parses CLI arguments,
- resolves the selected profile(s),
- invokes the generic library engine,
- writes `Module_Reload_Validation.res`.

### `lib_module_reload.sh`
Shared module reload engine that handles:
- module state checks,
- timeout-controlled unload/load execution,
- per-iteration evidence collection,
- timeout-path hang evidence,
- profile hook dispatch,
- result handling.

### `profiles/*.profile`
Each profile provides module-specific metadata and optional hook logic.

Example profile fields:
- `PROFILE_NAME`
- `PROFILE_DESCRIPTION`
- `MODULE_NAME`
- `PROFILE_MODE_DEFAULT`
- `PROFILE_REQUIRED_CMDS`
- `PROFILE_SERVICES`
- `PROFILE_DEVICE_PATTERNS`
- `PROFILE_SYSFS_PATTERNS`

Optional hooks:
- `profile_prepare`
- `profile_warmup`
- `profile_quiesce`
- `profile_post_unload`
- `profile_post_load`
- `profile_smoke`
- `profile_finalize`

## Current starter profile

### `fastrpc.profile`
Current profile covers FastRPC unload/reload validation and supports service lifecycle-based testing.

Default mode:
- `daemon_lifecycle`

Relevant services:
- `adsprpcd.service`
- `cdsprpcd.service`

## Execution flow
For each selected profile:

1. Validate the profile.
2. Ensure the module is loaded before starting iteration work.
3. Run warmup hook.
4. Capture pre-state logs.
5. Run quiesce hook.
6. Attempt module unload with timeout.
7. Validate module absence.
8. Run post-unload hook.
9. Attempt module reload with timeout.
10. Validate module presence.
11. Run post-load hook.
12. Run smoke hook.
13. Capture post-load state.
14. Repeat for all iterations.
15. Run finalize hook.

## Hang handling policy
Sysrq dump is **not** triggered on normal passing iterations.

It is triggered only when an unload/load action actually times out.

Current behavior:
- normal pass -> no sysrq dump
- quick non-timeout failure -> normal failure evidence only
- timeout / hang -> hang evidence bundle + optional sysrq dump

Default behavior in current suite:
- sysrq hang dump enabled
- but only used on timeout paths

## Evidence collected
Per profile / iteration, the suite can capture:
- command logs,
- `lsmod`,
- `modinfo`,
- `ps`,
- `dmesg`,
- service status and recent journal,
- profiled device path presence,
- profiled sysfs path presence,
- `/sys/module/<module>/holders`,
- timeout PID `/proc` snapshots,
- optional sysrq task/block dumps.

Results are stored under:

```text
results/Module_Reload_Validation/<profile>/iter_XX/
```

## CLI usage

### Run one profile
```sh
./run.sh --module fastrpc
```

### Run one profile with more iterations
```sh
./run.sh --module fastrpc --iterations 5
```

### Override mode
```sh
./run.sh --module fastrpc --mode daemon_lifecycle
./run.sh --module fastrpc --mode basic
```

### Override timeouts
```sh
./run.sh --module fastrpc --timeout-unload 60 --timeout-load 60 --timeout-settle 30
```

### Disable sysrq timeout-path dumps
```sh
./run.sh --module fastrpc --disable-sysrq-hang-dump
```

### Run all enabled profiles
```sh
./run.sh
```

If `--module` is empty or not given, the suite runs all profiles listed in `profiles/enabled.list`.

If `--mode` is empty or not given, the profile default mode is used.

## YAML usage in LAVA
Current YAML is generic and takes profile input from the test plan.

Important params:
- `PROFILE`
- `ITERATIONS`
- `MODE`
- `TIMEOUT_UNLOAD`
- `TIMEOUT_LOAD`
- `TIMEOUT_SETTLE`
- `ENABLE_SYSRQ_HANG_DUMP`

Behavior:
- `PROFILE="fastrpc"` -> runs only `fastrpc.profile`
- `PROFILE=""` -> runs all enabled profiles
- `MODE=""` -> uses the profile default mode

## How to add a new profile
1. Create a new file under `profiles/`, for example:
   - `profiles/ath11k_pci.profile`
2. Define the required metadata:
   - `PROFILE_NAME`
   - `MODULE_NAME`
3. Add hooks only if module-specific lifecycle handling is needed.
4. Add the profile basename to `profiles/enabled.list`.
5. Run locally with:

```sh
./run.sh --module ath11k_pci
```

No YAML duplication is needed for new profiles.

## Result policy

### PASS
- all requested iterations for a profile pass successfully.

### FAIL
- unload/load timeout,
- unload/load command failure,
- module state validation failure,
- profile hook failure,
- smoke validation failure.

### SKIP
- module not present,
- module built into the kernel,
- required commands not available,
- profile explicitly not reloadable.

## Notes
- This suite is intended for **profiled, supported modules**, not blind reload of every loaded kernel module.
- The current structure avoids hidden run.sh-to-library globals as much as possible by passing explicit arguments and hook context.
- Profile hooks receive context arguments from the engine, so module-specific logic can store logs in the correct iteration directory without depending on hidden globals.
