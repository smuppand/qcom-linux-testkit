Systemd Boot KPI: How to Use the Two Tests
==========================================

We provide two complementary tests for measuring systemd boot KPIs:

1. **Per-boot KPI collector**  
   `Boot_Systemd_Validate/run.sh`
2. **Reboot loop wrapper / KPI aggregator**  
   `Boot_Systemd_KPI_Loop/run.sh`

They are designed to work together but serve **different use-cases**.

Typical paths in qcom-linux-testkit:

```text
suites/Performance/Boot_Systemd_Validate/run.sh
suites/Performance/Boot_Systemd_KPI_Loop/run.sh
```

---

1. `Boot_Systemd_Validate` – Per-boot KPI collector
---------------------------------------------------

**Path (example):**

```text
suites/Performance/Boot_Systemd_Validate/run.sh
```

### Purpose

Runs **once per boot** and collects detailed systemd boot KPIs:

- `systemd-analyze time` (parsed into firmware/loader/kernel/userspace/total)
- `systemd-analyze blame` (full + top-20)
- `systemd-analyze critical-chain`
- `systemd-analyze plot` → `boot_analysis.svg` (optional)
- `systemd-analyze dot` → `boot.dot`
- `systemctl` unit dependency trees and per-unit state CSV
- Journals: full boot, warnings, errors (when `journalctl` is available)
- Optional **gating on required units** (e.g. “all critical services must be active”)
- Optional **KPI goal gating** using `--goal` or `--goal-file`
- Optional **platform-aware KPI goal lookup** using `--goal-platform`
- Optional **configurable goal deviation tolerance** using `--goal-tolerance-percent`
- **UEFI loader timings** from efivars (Init/Exec/Total) when EFI vars exist
- **Exclusion of slow services** from userspace/total (e.g. `systemd-networkd-wait-online.service`)

All logs are stored under a test-local directory:

```text
./logs_Boot_Systemd_Validate/
```

When `--iterations N` is passed, the script still runs **once**, but includes
this hint in the KPI output so that the KPI loop wrapper knows the intended
window size.

---

### Usage (CLI help)

The script has a built-in help that matches the implementation:

```text
Usage: ./run.sh [OPTIONS]

Options:
  --out DIR           Output directory for logs
  --required FILE     File listing systemd units that must become active
  --timeout S         Timeout per required unit
  --no-svg            Skip systemd-analyze plot SVG generation
  --boot-type TYPE    Tag boot type (e.g. cold, warm, unknown)
  --disable-getty     Disable serial-getty@ttyS0.service for this KPI run
  --disable-sshd      Disable sshd.service for this KPI run

  --goal SEC          Gate selected boot KPI metric against max allowed seconds

  --goal-file FILE    Platform-aware goal file containing boot KPI goals

  --goal-metric NAME  KPI metric to gate.
                      Default: boot_total_effective_sec

  --goal-tolerance-percent PCT
                      Allowed percentage deviation above goal before FAIL.
                      Default: 2

  --goal-platform NAME
                      Platform alias used to select a matching goal-file row.
                      If omitted, the script auto-detects from device model,
                      soc0 machine, family, soc_id, and hostname.

  --exclude-networkd-wait-online
                      Exclude systemd-networkd-wait-online.service time
                      from userspace/total based on systemd-analyze blame

  --exclude-services "svc1 svc2 ..."
                      Exclude one or more services (matching names in
                      systemd-analyze blame) from userspace/total.
                      The summed time is subtracted and reported as
                      an effective KPI.

  --iterations N      Hint for KPI iterations (wrapper/LAVA metadata; this
                      script still runs once per invocation)

  --verbose           Dump key .txt artifacts from OUT_DIR to console for
                      LAVA debugging (skips large journal_*.txt files)

  -h, --help          Show this help and exit
```

**Environment knobs (optional):**

- `TIMEOUT_PER_UNIT` – default per-unit wait time for `--required`
- `SVG=yes|no` – default for SVG generation (overridden by `--no-svg`)
- `BOOT_TYPE` – default boot type tag (overridden by `--boot-type`)
- `BOOT_KPI_ITERATIONS` – default for the `iterations` field in the KPI output
- `BOOT_GOAL` – default inline KPI goal, same as passing `--goal`
- `BOOT_GOAL_FILE` – default platform-aware goal file, same as passing `--goal-file`
- `BOOT_GOAL_METRIC` – default metric for KPI gating
- `BOOT_GOAL_TOLERANCE_PERCENT` – default allowed percentage deviation above goal before FAIL
- `BOOT_GOAL_PLATFORM` – optional platform alias override for goal-file matching

---

### Outputs / Artifacts

All written under `OUT_DIR` (default: `./logs_Boot_Systemd_Validate`):

- Platform + metadata  
  - `platform.txt`, `platform.json`  
  - `clocksource.txt` (current clocksource)  
  - `boot_type.txt` (e.g. `cold`, `warm`, `unknown`)

- Units & dependencies  
  - `sysinit_deps.txt`, `basic_deps.txt`  
  - `units.list`  
  - `unit_states.csv` (per-unit state/export from `systemctl show`)

- Systemd timing & graphs  
  - `analyze_time.txt` (raw `systemd-analyze time` output)  
  - `blame.txt`, `blame_top20.txt`  
  - `critical_chain.txt`  
  - `boot_analysis.svg` (unless `--no-svg`)  
  - `boot.dot`

- Journals  
  - `journal_boot.txt` – full boot journal  
  - `journal_warn.txt` – warnings and above  
  - `journal_err.txt` – errors and above

- Bootchart (if enabled via `init=/lib/systemd/systemd-bootchart`)  
  - `bootchart.tgz` (if present under `/run/log/...`)

- Required units  
  - `failed_units.txt` (from `systemctl --failed`)

- **KPI breakdown (this run)**  
  - `boot_kpi_this_run.txt` – structured, human-readable KPI summary

- **Optional KPI goal check**  
  - `boot_kpi_goal_check.txt` – written only when `--goal` or `--goal-file` is used

---

### KPI breakdown: fields and exclusions

At the end of the run, the script prints a KPI summary **to console** and
writes the same content into `boot_kpi_this_run.txt`, for example:

```text
Boot KPI (this run)
 boot_type : cold
 iterations : 5
 clocksource : arch_sys_counter
 uefi_time_sec : 438093.283 (Init=214751.707, Exec=223341.576)
 firmware_time_sec : 3.765
 bootloader_time_sec : 0.176
 kernel_time_sec : 6.124
 userspace_time_sec : 126.942
 userspace_effective_time_sec : 6.825
 boot_total_sec : 137.008
 boot_total_effective_sec : 16.891
```

Fields:

- `uefi_time_sec`  
  Sum of UEFI loader Init+Exec time in seconds, derived from EFI vars:

  - `LoaderTimeInitUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f`
  - `LoaderTimeExecUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f`

- `firmware_time_sec`, `bootloader_time_sec`, `kernel_time_sec`,
  `userspace_time_sec`, `boot_total_sec`  
  Parsed from `systemd-analyze time`.

- `userspace_effective_time_sec`, `boot_total_effective_sec`

  These are derived from the raw userspace/total time by subtracting:

  1. `systemd-networkd-wait-online.service` time when
     `--exclude-networkd-wait-online` is passed.
  2. Any additional services given via `--exclude-services "svc1 svc2"`.

If `systemd-analyze time` reports that boot is not yet finished, the script
marks the timing fields as `unknown` and captures active jobs for debugging.

---

### Optional KPI goal gating

By default, `Boot_Systemd_Validate` is measurement-only. It collects boot KPI
data and reports PASS/FAIL based on required unit validation and script health.

KPI goal gating is enabled only when the user explicitly provides one of:

```sh
--goal <seconds>
--goal-file <file>
```

The default metric is:

```text
boot_total_effective_sec
```

Supported goal metrics:

```text
uefi_time_sec
firmware_time_sec
bootloader_time_sec
kernel_time_sec
userspace_time_sec
userspace_effective_time_sec
boot_total_sec
boot_total_effective_sec
```

All goal checks are lower-is-better.

With tolerance enabled, the failure rule is:

```text
current_sec > goal_sec + tolerance_percent => FAIL
```

The default tolerance is:

```text
2%
```

For example, if:

```text
goal_sec=20.600
tolerance_percent=2
```

then:

```text
allowed_max_sec=21.012
```

The check passes when:

```text
current_sec <= 21.012
```

#### Inline goal

```sh
./run.sh --goal 35 --goal-metric boot_total_effective_sec
```

To override tolerance:

```sh
./run.sh --goal 35 --goal-tolerance-percent 5
```

#### Platform-aware goal file

A goal file uses this format:

```text
<platform_aliases> <metric> <goal_sec> [tolerance_percent]
```

Example:

```text
# platform aliases                  metric                    goal    tolerance
qcm6490,qcs6490,rb3gen2-core-kit     boot_total_effective_sec  20.600  2
qcs8300,iq-8275-evk                  boot_total_effective_sec  25.500  2
```

`platform_aliases` can be comma-separated.

The script auto-detects the platform from:

- `/proc/device-tree/model`
- `/sys/devices/soc0/machine`
- `/sys/devices/soc0/family`
- `/sys/devices/soc0/soc_id`
- hostname

If the runtime machine string is not stable, pass an explicit alias:

```sh
./run.sh   --goal-file boot_kpi_goals --goal-platform rb3gen2-core-kit
```

#### Goal check report

When goal gating is enabled, the script writes:

```text
boot_kpi_goal_check.txt
```

under `OUT_DIR`.

Example PASS content:

```text
metric=boot_total_effective_sec
current_sec=20.700
goal_sec=20.600
tolerance_percent=2
direction=lower_or_equal_with_tolerance
allowed_max_sec=21.012
delta_from_allowed_sec=-0.312
result=PASS
```

Example FAIL content:

```text
metric=boot_total_effective_sec
current_sec=21.500
goal_sec=20.600
tolerance_percent=2
direction=lower_or_equal_with_tolerance
allowed_max_sec=21.012
delta_from_allowed_sec=0.488
result=FAIL
```

#### Notes

- Goal gating is disabled unless `--goal` or `--goal-file` is provided.
- The example goal file is not used automatically.
- This keeps existing KPI collection behavior unchanged for normal runs.
- CI/LAVA jobs can opt into gating only when they want boot KPI thresholds enforced.
- The default tolerance is 2%, but CI can override it per job using
  `--goal-tolerance-percent` or `BOOT_GOAL_TOLERANCE_PERCENT`.

---

### Verbose mode (`--verbose`)

When `--verbose` is set, the script prints reasonable `.txt` artifacts from
`OUT_DIR` to console, excluding large `journal_*.txt` files.

---

### Typical usage examples

**1) Basic per-boot KPI with required units**

```sh
./run.sh   --timeout 60   --required required-units.txt
```

**2) Cold-boot KPI, excluding networkd-wait-online + Docker/Weston**

```sh
./run.sh   --boot-type cold   --disable-getty   --exclude-networkd-wait-online   --exclude-services "docker.service weston.service"
```

**3) LAVA-friendly verbose run**

```sh
./run.sh   --boot-type warm   --disable-getty   --exclude-networkd-wait-online   --iterations 5   --verbose
```

**4) Gate boot total effective time with an inline goal**

```sh
./run.sh   --boot-type cold   --exclude-networkd-wait-online   --goal 35
```

**5) Gate a specific KPI metric**

```sh
./run.sh   --boot-type cold   --goal 25   --goal-metric userspace_effective_time_sec
```

**6) Gate using a platform-aware goal file**

```sh
./run.sh   --boot-type cold   --exclude-networkd-wait-online   --goal-file boot_kpi_goals --goal-platform rb3gen2-core-kit   --goal-metric boot_total_effective_sec
```

**7) Gate using a goal file with custom tolerance**

```sh
./run.sh   --goal-file boot_kpi_goals --goal-platform qcs8300   --goal-tolerance-percent 5
```

The main KPI is in:

```text
logs_Boot_Systemd_Validate/boot_kpi_this_run.txt
```

When goal gating is enabled, the goal check report is in:

```text
logs_Boot_Systemd_Validate/boot_kpi_goal_check.txt
```

---

2. `Boot_Systemd_KPI_Loop` – Reboot loop wrapper & KPI aggregator
-----------------------------------------------------------------

**Path (example):**

```text
suites/Performance/Boot_Systemd_KPI_Loop/run.sh
```

### Purpose

A **thin wrapper** that drives multiple KPI iterations across reboots and
computes averages over the last **N boots** of a given `boot_type`.

On each (re)boot it:

1. Loads state from `Boot_Systemd_KPI_Loop.state` if present.
2. Computes this iteration index and a per-iteration out dir.
3. Calls `Boot_Systemd_Validate/run.sh` once.
4. Parses `boot_kpi_this_run.txt`.
5. Appends a row into `Boot_Systemd_KPI_stats.csv`.
6. Computes averages into `Boot_Systemd_KPI_summary.txt`.
7. In auto-reboot mode, updates state and reboots until all iterations complete.

When all iterations finish, the wrapper prints the KPI average summary,
leaves `.csv` and `.summary.txt` for analysis, and cleans up the systemd
hook and state file in auto-reboot mode.

---

### Usage (CLI help)

```text
Usage: ./run.sh [OPTIONS]

This wrapper:
  * Runs Boot_Systemd_Validate once for the current boot
  * Uses a per-iteration KPI out dir when --iterations > 1
  * Parses boot_kpi_this_run.txt from that test
  * Appends a row into Boot_Systemd_KPI_stats.csv
  * Computes averages over the last N boots and prints summary.

Options:
  --kpi-script PATH
  --kpi-out-dir DIR
  --iterations N
  --boot-type TYPE
  --disable-getty
  --disable-sshd
  --exclude-networkd-wait-online
  --exclude-services "A B"
  --no-svg
  --verbose
  --auto-reboot
  -h, --help
```

---

### Files written by the loop wrapper

Under the same directory as `Boot_Systemd_KPI_Loop/run.sh`:

- `Boot_Systemd_KPI_Loop.res`
- `Boot_Systemd_KPI_Loop.state`
- `Boot_Systemd_KPI_stats.csv`
- `Boot_Systemd_KPI_summary.txt`
- `Boot_Systemd_KPI_Loop_stdout_<timestamp>.log`

Per-iteration artifacts from `Boot_Systemd_Validate` live under:

```text
../Boot_Systemd_Validate/logs_Boot_Systemd_Validate/iter_1/
../Boot_Systemd_Validate/logs_Boot_Systemd_Validate/iter_2/
...
```

---

### Auto-reboot mode details

When `--auto-reboot` is passed:

- The wrapper installs a small systemd service.
- On each boot, it runs `Boot_Systemd_Validate` once.
- If more iterations are required, it requests reboot again.
- After the final iteration, it computes averages, removes the hook, and
  deletes the state file.

---

### Typical usage examples

**1) Manual KPI over last 5 cold boots**

```sh
./run.sh --iterations 5 --boot-type cold --disable-getty --exclude-networkd-wait-online
```

**2) Fully automated cold-boot KPI campaign**

```sh
./run.sh   --iterations 5   --boot-type cold   --disable-getty   --exclude-networkd-wait-online   --auto-reboot
```

**3) Warm-boot KPI with extra service exclusions and verbose logs**

```sh
./run.sh   --iterations 3   --boot-type warm   --disable-getty   --exclude-networkd-wait-online   --exclude-services "docker.service weston.service"   --auto-reboot   --verbose
```

---

3. Which one should I use?
--------------------------

| Scenario                                      | Recommended test                      | Notes                                                                 |
|----------------------------------------------|---------------------------------------|-----------------------------------------------------------------------|
| Standard CI pipeline (no reboot-resume)      | `Boot_Systemd_Validate`               | Run once per job; no reboot inside the script.                        |
| Manual KPI measurement on a single boot      | `Boot_Systemd_Validate`               | E.g. after changing kernel/systemd configs.                           |
| Quick health-check of systemd units          | `Boot_Systemd_Validate`               | Use `--required` to gate on critical services.                        |
| Lab KPI across N cold/warm boots             | `Boot_Systemd_KPI_Loop`               | Wrapper handles per-boot dirs + CSV + averages.                       |
| Automated multi-boot campaign in lab         | `Boot_Systemd_KPI_Loop` with `--auto-reboot` | State file + systemd hook handle the full loop.                 |
| CI with explicit reboot-resume support       | `Boot_Systemd_KPI_Loop` if allowed    | CI must re-run the script after each reboot.                          |

---

4. Design principles
--------------------

- **Single responsibility**
  - `Boot_Systemd_Validate`: measure one boot and emit KPIs.
  - `Boot_Systemd_KPI_Loop`: across boots: state, reboots, aggregation.

- **CI friendliness**
  - CI that cannot handle reboots should only use `Boot_Systemd_Validate`.
  - Reboot orchestration via `--auto-reboot` is explicitly opt-in.

- **Robust & transparent**
  - Rolling CSV + summary for long-term trends.
  - Clear console logs for service time exclusions, non-finished boots,
    per-iteration KPI values, and optional goal gating results.

- **Local logs only**
  - All artifacts are stored under the test working directory, making log
    collection and LAVA parsing straightforward.

