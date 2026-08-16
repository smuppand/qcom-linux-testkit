Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# MinkIPC SMCInvoke Internal Validation

Runs one internal MinkIPC filesystem test through the optional `smplap64.mbn`
TA:

```sh
smcinvoke_client -i <TA path> <command> <iterations> <type>
```

The default command is `6`, the FS test. Command `5`, the GPFS test, is also
allowed. Commands `14`, `15`, and `17` are deliberately blocked because they
can provision, erase, or write RPMB state.

Application type `0` selects the default 64-bit request and type `1` selects
the 32-bit request format supported by the public client.

## Run

```sh
cd Runner
./run-test.sh MinkIPC_SMCInvoke_Internal_Validation
```

Direct options:

```sh
./run.sh --ta /data/smplap64.mbn
./run.sh --command 5 --iterations 5
./run.sh --type 1 --ta /data/smplap64.mbn
```

The suite searches the standard QTEE TA directories when no TA path is
supplied. It requires both a zero client exit status and the exact
`TEST SUCCEEDED` marker because the public client can overwrite a command
failure return code during TA unload. Missing optional assets produce `SKIP`.

On Debian and Ubuntu, the mapped MinkIPC runtime and test packages are
automatically installed from the Qualcomm `qli-staging` trixie repository.
Those packages provide `smcinvoke_client`, but they do not contain
`smplap64.mbn`; that optional TA must still be provisioned separately. Yocto,
CentOS, and other images use their image-provided components.
