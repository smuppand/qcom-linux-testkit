Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# RMTFS Validation

Functional runtime health validation for the public
[linux-msm/rmtfs](https://github.com/linux-msm/rmtfs) daemon, with explicit
fallbacks for legacy `rmt_storage` deployments.

Focused diagnostics are separate suites:

- `RMTFS_QMI_Service_Validation`
- `RMTFS_Shared_Memory_Validation`
- `RMTFS_Partition_Read_Validation`

## Applicability

RMTFS is not present on every Qualcomm platform. Applicability is determined
from the runtime `qcom,rmtfs-mem` device tree, an existing shared-memory
device, or an active RMTFS implementation. `CONFIG_QCOM_RMTFS_MEM` and an
installed module file are logged but are not treated as hardware evidence,
because those build artifacts are shared by `meta-qcom` machines with and
without RMTFS hardware.

The current public `meta-qcom` machine set was reviewed against the public
`qualcomm-linux/kernel` device trees. The test intentionally uses runtime DT
evidence rather than a machine-name allowlist so new machines and downstream
device-tree variants remain supported.

## Module and service lifecycle

When applicable hardware is present and `rmtfs_mem` is not loaded, the suite:

1. Locates and logs the running-kernel module file.
2. Loads it using repository module helpers.
3. Waits for the matching `/dev/qcom_rmtfs_mem*` device and starts the image-provided service when needed.
4. Runs functional validation.
5. Stops only a service activated during the test and unloads only a module loaded by the test.

An initially loaded module and initially active service are never removed.

## Test cases

| ID | Validation |
|---|---|
| TC-00 | Runtime DT, module presence/load, and usable shared-memory interface |
| TC-01 | Mainline `rmtfs` or legacy `rmt_storage` service/process health |
| TC-02 | Binary availability matching the detected implementation |
| TC-03 | QRTR or legacy IPC transport without assuming `/dev/qrtr` exists |
| TC-04 | Relevant kernel-log error scan with retained snapshot and filtered error logs |
| TC-05 | Restoration of the initial module and service state |

## Distribution support

- Yocto: validates the image-provided `rmtfs` recipe and service.
- Debian/Ubuntu: supports the public `rmtfs` package and systemd layout.
- CentOS/RHEL family: validates image-provided RPM content without assuming an unverified package name.

No package manager or network operation is performed on the target.

## Run

```sh
cd Runner
./run-test.sh RMTFS_Validation
```
