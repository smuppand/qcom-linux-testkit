Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# MinkIPC Validation

Health validation for the Qualcomm MinkIPC userspace-to-QTEE path.
The checks follow the public [qualcomm/minkipc](https://github.com/qualcomm/minkipc)
implementation while retaining compatibility with the legacy
`/dev/smcinvoke` interface.

This suite does not run asset-dependent diagnostics. Those are separate tests:

- `MinkIPC_SMCInvoke_Validation`
- `MinkIPC_SMCInvoke_Callback_Validation`
- `MinkIPC_SMCInvoke_Memory_Object_Validation`
- `MinkIPC_SMCInvoke_Internal_Validation`
- `MinkIPC_GPTEEC_Validation`

## Applicability

The suite returns `SKIP` when no Qualcomm SMCInvoke/QCOMTEE hardware signal is
present. A generic `/dev/tee*` node is accepted only when QCOMTEE backing can be
identified through sysfs or the installed MinkIPC runtime and
`qtee_supplicant` service.

The public `meta-qcom` build links the static `qcomtee` library privately into
`libminkadaptor`, so a separate runtime `libqcomtee.so` is not required.

## Test cases

| ID | Validation |
|---|---|
| TC-01 | Legacy `/dev/smcinvoke` or QCOMTEE-backed TEE character device |
| TC-02 | Architecture-neutral `libminkadaptor` and optional `libminkteec` discovery |
| TC-03 | `qtee_supplicant` process and systemd/SysV service health |
| TC-04 | `sfsconfig.service` result, persistent-mount ordering, and SFS directories |
| TC-05 | Device-node read/write accessibility |
| TC-06 | Relevant kernel-log error scan with retained snapshot and filtered error logs |

## Distribution support

- Yocto: validates image-provided `minkipc` and `minkipc-qteesupplicant` components.
- Debian/Ubuntu: automatically ensures `libminkadaptor0`, `libminkteec1`,
  `minkipc-qteesupplicant`, and `minkipc-tests` from the Qualcomm
  `qli-staging` trixie repository before validation.
- CentOS/RHEL family: supports `/lib64`/`/usr/lib64`, RPM images, systemd, and SysV fallback.

Only Debian and Ubuntu use package recovery. Yocto, CentOS, and other images
continue using their image-provided components.

## Run

```sh
cd Runner
./run-test.sh MinkIPC_Validation
```

The result file contains one of:

```text
MinkIPC_Validation PASS
MinkIPC_Validation FAIL
MinkIPC_Validation SKIP
```
