# Kernel_Selftests_Validation

This test suite runs a selected set of kernel selftests for ARM64-based Qualcomm platforms like RB3GEN2.

## Files

- `run.sh` — Executes selected kernel selftests using a whitelist approach.
- `enabled_tests.list` — Defines which test folders or binaries to run under `/kselftest`.
- `*.log` — Per-test logs.
- `Kernel_Selftests_Validation.res` — Result file for CI/LAVA.

## Features

- Supports suite-level test entries (e.g., `timers`, `watchdog`)
- Discovers and runs each `*test` binary or `run_test.sh`
- Tracks pass/fail/skip per binary and per suite
- CI/LAVA-compatible `.res` file

## Usage

1. Ensure `/kselftest` is available and populated on target.
2. Update `enabled_tests.list` with one test folder per line.
3. Run the script:

```sh
chmod +x run.sh
./run.sh
```

## Output

- `*.log`: logs per test binary
- `Kernel_Selftests_Validation.res`: CI-compatible result summary
