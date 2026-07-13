# DIAG_Functional_Validation

## Overview

`DIAG_Functional_Validation` validates the Qualcomm DIAG userspace logging path on QLI Yocto, Debian, and Ubuntu targets.

The testcase focuses on safe, non-destructive validation of:

- DIAG userspace tool availability
- `diag-router` process and Unix socket visibility
- pre-existing `diag_mdlog` sessions
- owned `diag_mdlog` startup and DIAG LSM initialization
- socket connection and peripheral logging activation
- bounded output-file configuration
- output-directory and non-empty log-file generation
- mask-aware PASS, FAIL, and SKIP handling
- clean shutdown of processes started by the testcase
- `diag_mdlog -b` non-real-time mode
- runtime capability discovery for optional DIAG utilities

The testcase never kills a DIAG process that it did not start.

## Test Location

```text
Runner/suites/System/Logging/DIAG_Functional_Validation/
```

Shared helpers are located at:

```text
Runner/utils/diag/lib_diag.sh
```

## Files

```text
Runner/suites/System/Logging/DIAG_Functional_Validation/
├── run.sh
├── DIAG_Functional_Validation.yaml
└── README.md

Runner/utils/diag/
└── lib_diag.sh
```

## Validation Flow

### 1. Tool inventory

The testcase checks for:

- `diag_mdlog`
- `diag-router`
- `diag_klog`
- `diag_socket_log`
- `diag_uart_log`
- `diag_callback_sample`
- `diag_dci_sample`

`diag_mdlog` is the required core utility. The remaining tools are treated as optional capabilities.

The testcase always captures `diag_mdlog` help because its interface is required for core validation. Optional utility help probing is disabled by default to avoid accidentally starting an unknown overlay utility that does not implement conventional help handling. Set `DIAG_PROBE_OPTIONAL_HELP=1` to collect `--help` or `-h` output for optional tools. Optional missing utilities are reported as subtest SKIPs and do not skip the complete testcase.

### 2. DIAG infrastructure

The testcase checks:

- whether `diag-router` is already running
- whether a named DIAG Unix socket is visible in `/proc/net/unix`
- whether `diag_mdlog` can connect to the active DIAG infrastructure

A standalone `diag-router` process is not mandatory when `diag_mdlog` provides successful connection evidence.

### 3. Existing-session protection

Before starting logging, the testcase scans `/proc` for existing `diag_mdlog` instances.

When an existing session is found:

- it is not killed
- a second conflicting session is not started
- the existing process command line and UID are recorded
- its `-o` output path is inspected when available
- owned normal and non-real-time session checks are marked SKIP
- the overall testcase can still PASS when the existing session is alive and functional evidence is available

### 4. Owned normal logging session

When no existing session is active, the testcase starts an owned session using bounded parameters:

```sh
diag_mdlog -o <test-output-dir> -s <size> -n <count>
```

It validates:

- process remains active for the configured duration
- `Diag_LSM_Init` success evidence
- DIAG socket connection evidence
- `logging switched` evidence
- output-directory creation
- non-empty data files when data is available
- mask application behavior
- clean TERM-based shutdown

The testcase uses a dedicated artifact path and changes permissions only on that test-owned path. It does not run `chmod 777 /sdcard` or modify unrelated directories.

### 5. Mask-aware data validation

Without an explicit mask, `diag_mdlog` may report that default mask files are absent and continue with masks previously configured on the device.

The testcase applies these rules:

| Condition | Result |
|---|---|
| Explicit readable mask supplied and non-empty data is created | PASS |
| Explicit mask supplied but cannot be read | FAIL |
| Explicit mask supplied but no non-empty data is created | FAIL |
| No explicit mask and prior masks produce data | PASS |
| No explicit mask and no data is produced | SKIP for data-content check |

Messages such as the following are not treated as fatal when no explicit mask was requested:

```text
No successful mask file reads.
Running with masks that were set prior to diag_mdlog start-up.
```

### 6. Non-real-time mode

When supported and enabled, the testcase starts a second owned session with:

```sh
diag_mdlog ... -b
```

This check runs only after the normal owned session has been stopped. It is skipped when another DIAG session is active or when the runtime help does not advertise `-b`.

Non-real-time mode validates startup, DIAG initialization, connection evidence, output handling, and clean shutdown. Non-empty data is not mandatory because peripheral buffering and flush behavior can vary.

## Safety Rules

The testcase intentionally avoids destructive behavior:

- does not kill pre-existing `diag_mdlog` processes
- does not invoke `diag_mdlog -k`
- does not restart `diag-router`
- does not globally change `/sdcard` permissions
- does not enable mask cleanup with `-c`
- does not disable console logging with `-d`
- does not request a wake lock with `-e`
- cleans up only PIDs started by the testcase

## Dependencies

Required core command:

```text
diag_mdlog
```

Required base shell utilities:

```text
awk sed grep find wc tail tr chmod mkdir date head basename
```

Optional DIAG commands are reported individually.

## Command-Line Options

```text
--duration <seconds>
--nrt-duration <seconds>
--file-size <value>
--file-count <count>
--mask-file <path>
--mask-list <path>
--peripheral-mask <mask>
--no-nonrealtime
--help
```

## Environment Variables

### Core controls

- `DIAG_DURATION_SECS`
  - normal-session observation time
  - default: `10`

- `DIAG_NRT_DURATION_SECS`
  - non-real-time-session observation time
  - default: `5`

- `DIAG_STARTUP_TIMEOUT_SECS`
  - time allowed for initialization evidence
  - default: `15`

- `DIAG_STOP_TIMEOUT_SECS`
  - TERM shutdown timeout before forced cleanup
  - default: `5`

- `DIAG_FILE_SIZE`
  - value passed to `diag_mdlog -s`
  - default: `20`
  - the tested runtime help describes this as maximum file size in MB

- `DIAG_FILE_COUNT`
  - value passed to `diag_mdlog -n`
  - default: `2`

- `DIAG_TEST_NONREALTIME`
  - `1` enables the `-b` validation
  - default: `1`

- `DIAG_ARTIFACT_DIR`
  - root directory for help output, command logs, summaries, and DIAG data
  - default: `./diag_artifacts`

- `DIAG_KEEP_ARTIFACTS`
  - `1` retains artifacts after execution
  - default: `1`

- `DIAG_PROBE_OPTIONAL_HELP`
  - `1` probes `--help`/`-h` for optional DIAG utilities
  - default: `0`
  - keep disabled until the overlay tools are known to implement side-effect-free help handling

### Mask controls

Only one of these should be supplied:

- `DIAG_MASK_FILE`
  - passed using `diag_mdlog -f`

- `DIAG_MASK_LIST`
  - passed using `diag_mdlog -l`

### Platform-specific optional controls

These are used only when explicitly set and advertised by the runtime help:

- `DIAG_PERIPHERAL_MASK` → `-p`
- `DIAG_PROCESSOR_MASK` → `-j`
- `DIAG_USERPD_MASK` → `-g`
- `DIAG_QDSS_MASK` → `-q`
- `DIAG_TX_MODE` → `-t`
- `DIAG_BUFFER_PERIPHERAL_MASK` → `-x`
- `DIAG_ETR_BUFFER_SIZE` → `-y`
- `DIAG_QMDL2_V2=1` → `-u`

## Examples

Run with defaults:

```sh
cd Runner/suites/System/Logging/DIAG_Functional_Validation
./run.sh
```

Run for 20 seconds and retain four bounded files:

```sh
./run.sh --duration 20 --file-size 50 --file-count 4
```

Run with an explicit mask:

```sh
./run.sh --mask-file /path/to/Diag.cfg
```

Run with a mask list:

```sh
./run.sh --mask-list /path/to/Diag_list.txt
```

Run with a platform peripheral mask:

```sh
./run.sh --peripheral-mask 0x1FFFFF
```

Disable non-real-time validation:

```sh
./run.sh --no-nonrealtime
```

Use environment variables:

```sh
DIAG_DURATION_SECS=15 \
DIAG_FILE_SIZE=50 \
DIAG_FILE_COUNT=5 \
DIAG_TEST_NONREALTIME=1 \
./run.sh
```

## Artifacts

A run-specific directory is created under:

```text
./diag_artifacts/run_<pid>/
```

Typical contents include:

```text
results.tsv
tool_help/
normal_diag_mdlog.log
normal_output/
nonrealtime_diag_mdlog.log
nonrealtime_output/
```

The full paths are printed to stdout for LAVA debugging.

## Result Rules

### PASS

The testcase passes when:

- `diag_mdlog` is installed
- an existing or testcase-owned DIAG logging session is validated
- no mandatory subtest fails
- owned processes are cleaned up successfully

### FAIL

The testcase fails when:

- installed `diag_mdlog` cannot initialize or remain active
- a fatal socket or LSM startup error is detected
- an explicit mask cannot be read
- an explicit mask produces no non-empty data
- a testcase-owned process cannot be stopped cleanly
- an explicitly requested runtime option is unsupported

### SKIP

The testcase is skipped when:

- `diag_mdlog` is not installed
- DIAG functionality cannot be safely exercised
- only optional capabilities are available

Individual optional checks can be SKIP while the overall testcase remains PASS.

## Result File

```text
DIAG_Functional_Validation.res
```

Possible values:

```text
DIAG_Functional_Validation PASS
DIAG_Functional_Validation FAIL
DIAG_Functional_Validation SKIP
```

The script exits `0` after writing the result file so LAVA can continue and report the `.res` result.

## Current Coverage and Planned Extensions

The first version functionally validates the core `diag_mdlog` path and inventories optional tools.

The following optional utilities are capability-only until their exact runtime command-line behavior is confirmed on the target image:

- `diag_klog`
- `diag_socket_log`
- `diag_uart_log`
- `diag_callback_sample`
- `diag_dci_sample`

When `DIAG_PROBE_OPTIONAL_HELP=1`, their captured help output is retained in the artifact directory and can be used to add safe functional subtests without hardcoding incompatible command-line assumptions.
