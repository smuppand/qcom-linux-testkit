# Qualcomm BWMON validation

`QCOM_BWMON_Validation` validates enabled Qualcomm CPU and LLCC bandwidth
monitor nodes, their required `reg`, interrupt, interconnect, and OPP-table DT
resources, and binding to the upstream
`qcom-bwmon` driver.

When an image-provided workload is available, the suite runs a bounded memory
load using `stress-ng`, `stressapptest`, or `dd`. It samples the ICC summary and
checks for a BWMON interrupt-count increase. These runtime observations are
supplemental: no interrupt delta or vote increase is not a failure because the
device may already be at its current maximum OPP or may not cross a programmed
threshold during the sample window.

## Configuration

```text
--load-seconds N
```

The equivalent LAVA environment variable is `LOAD_SECONDS`. The command-line
value takes precedence.

The test does not require exact bandwidth values, force an ICC vote, alter an
OPP table, or install a benchmark package. Missing optional workload and
debugfs support produce skipped subchecks. An absent BWMON node skips the
suite, while an applicable but unbound or malformed node fails it.
