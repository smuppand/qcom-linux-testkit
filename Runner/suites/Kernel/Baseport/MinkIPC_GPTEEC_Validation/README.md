Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# MinkIPC GP TEEC Validation

Runs the public `gp_test_client` GlobalPlatform Client API tests with explicitly
pre-loaded Trusted Applications:

```sh
gp_test_client -l /path/to/gp/tas
```

The supplied directory must contain:

- `example_gpapp_ta32.mbn`
- `gpsample.mbn`
- `gpsample2.mbn`
- `gptest.mbn`
- `gptest2.mbn`

This corrects the previous behavior that checked a custom TA path but then ran
`gp_test_client -a`, which ignored that path.

## Run

```sh
cd Runner
GP_TA_PATH=/data/gp-tas ./run-test.sh MinkIPC_GPTEEC_Validation
```

Direct options:

```sh
./run.sh --ta-path /data/gp-tas
./run.sh --client /opt/minkipc/gp_test_client --ta-path /data/gp-tas
```

The suite auto-discovers complete TA sets under `/lib/qtee-tas`,
`/usr/lib/qtee-tas`, `/data`, and `/opt/minkipc-ta`. Missing test assets produce
`SKIP`, not a platform failure.

On Debian and Ubuntu, the mapped MinkIPC runtime and test packages are
automatically installed from the Qualcomm `qli-staging` trixie repository.
The `minkipc-tests` package provides `gp_test_client`, but the five GP test TAs
are not included and must be provisioned separately. Yocto, CentOS, and other
images use their image-provided components.
