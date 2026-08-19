Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# MinkIPC SMCInvoke Callback Validation

Runs the public MinkIPC callback object test:

```sh
smcinvoke_client -c <TA directory> <iterations>
```

The directory must contain `tzecotestapp.mbn`. The suite searches
`/lib/qtee-tas`, `/usr/lib/qtee-tas`, `/data`, and `/opt/minkipc-ta` when no
directory is supplied.

## Run

```sh
cd Runner
./run-test.sh MinkIPC_SMCInvoke_Callback_Validation
```

Direct options:

```sh
./run.sh --iterations 5
./run.sh --ta-dir /lib/qtee-tas
./run.sh --client /opt/minkipc/smcinvoke_client
```

The suite requires a zero client exit status and the public client's
`TEST PASSED!` marker. It returns `SKIP` when the client, device node, or test
TA is not provisioned.

On Debian and Ubuntu, the mapped MinkIPC runtime and test packages are
automatically installed from the Qualcomm `qli-staging` trixie repository.
Those packages provide `smcinvoke_client`, but they do not contain
`tzecotestapp.mbn`; that optional TA must still be provisioned separately.
Yocto, CentOS, and other images use their image-provided components.
