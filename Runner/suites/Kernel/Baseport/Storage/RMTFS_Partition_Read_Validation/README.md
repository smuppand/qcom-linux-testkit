Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# RMTFS Partition Read Validation

Performs isolated, read-only checks of RMTFS partition labels. Search order is:

1. `/dev/disk/by-partlabel`
2. `/dev/disk/by-name`
3. `/dev/block/by-name`
4. platform-specific Android-style `by-name` directories

The default labels are `modemst1 modemst2 fsc fsg`. Each discovered block
device is read for one 512-byte sector with output discarded. Partition data is
never printed or written, and the test does not attempt to decide whether the
sector is all-zero.

```sh
cd Runner
./run-test.sh RMTFS_Partition_Read_Validation
```

Direct customization:

```sh
./run.sh --partitions "modemst1 modemst2 study tunning"
```

The suite prepares the same reversible module and service lifecycle used by
the other RMTFS tests. If the running daemon uses `-P`, missing requested
partition labels are a failure. Missing labels produce `SKIP` only for a
directory-backed daemon or a deployment where partition mode is not used.
