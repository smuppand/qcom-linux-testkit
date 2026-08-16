Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# RMTFS Shared Memory Validation

Validates the shared-memory path used by RMTFS without mixing it with daemon,
QMI-registration, or partition-content checks.

Coverage includes:

- `CONFIG_QCOM_RMTFS_MEM`
- `rmtfs_mem`/`qcom_rmtfs_mem` module or built-in driver
- `qcom,rmtfs-mem` device-tree compatibility
- `/dev/qcom_rmtfs_mem*` plus `phys_addr` and `size` sysfs attributes
- `/dev/qcom_rmtfs_uio*` and legacy UIO devices named `rmtfs`
- reserved-memory plus `/dev/mem` fallback used by public `linux-msm/rmtfs`

If the runtime device tree is applicable and `rmtfs_mem` is not loaded, the
suite logs the module file, loads it temporarily, validates the resulting
device and sysfs attributes, then unloads it. A module that was already loaded
is left loaded. Services activated by the temporary module insertion are also
restored to their initial state.

Kernel configuration or module-package presence alone does not make RMTFS
applicable, which avoids false failures on supported `meta-qcom` machines whose
device trees do not contain an RMTFS region.

```sh
cd Runner
./run-test.sh RMTFS_Shared_Memory_Validation
```

The suite is distribution-neutral and does not install packages.
