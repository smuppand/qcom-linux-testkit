Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# MinkIPC SMCInvoke Validation

Runs the public MinkIPC QTEE diagnostic command:

```sh
smcinvoke_client -d 1
```

The test is separate from `MinkIPC_Validation` because the diagnostic
client may be delivered only in test-enabled images.

## Run

```sh
cd Runner
./run-test.sh MinkIPC_SMCInvoke_Validation
```

Direct options:

```sh
./run.sh --iterations 5
./run.sh --client /opt/minkipc/smcinvoke_client
```

On Debian and Ubuntu, the suite automatically ensures the mapped MinkIPC
runtime and test packages from the Qualcomm `qli-staging` trixie repository.
Yocto, CentOS, and other images continue using image-provided components. The
suite returns `SKIP` when the client or a supported device node remains absent.
