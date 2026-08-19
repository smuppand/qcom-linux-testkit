Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# RMTFS QMI Service Validation

Uses `qrtr-lookup` to validate the service published by public
`linux-msm/rmtfs`:

- service: `14`
- version: `1`
- instance: `0`

The values can be overridden with `RMTFS_QMI_SERVICE`, `RMTFS_QMI_VERSION`, and
`RMTFS_QMI_INSTANCE` for a documented downstream implementation.

On an applicable mainline platform, the suite temporarily loads `rmtfs_mem`
and starts the image-provided service when necessary. Failure to start the
daemon is a test failure. It returns `SKIP` for non-RMTFS platforms, legacy
`rmt_storage` deployments, or images without the optional `qrtr-lookup`
diagnostic. Module and service state are restored after the lookup.

```sh
cd Runner
./run-test.sh RMTFS_QMI_Service_Validation
```
