# MinkIPC QTEE PKCS#11 Validation

This suite validates the Qualcomm QTEE PKCS#11 Trusted Application through
MinkIPC with `xtest_qtee`. The suite is pinned to `-t pkcs11`; regression,
benchmark, performance, statistics, and internal applets are outside its scope.

## Prerequisites

- A Qualcomm QCOMTEE or SMCInvoke device accessible to the test user.
- A running `qtee_supplicant` with TA autoload, filesystem, and RPMB listeners.
- Successful secure-filesystem initialization and writable persistent storage.
- RPMB provisioned for QTEE secure storage.
- The PKCS#11 test TA:

  `FD02C9DA-306C-48C7-A49C-BBD827AE86EE.mbn`

The TA autoloader first checks `/data`, then derives
`/lib/qtee-tas/<platform>/` from every runtime device-tree compatible string
after removing the vendor prefix. The runner follows the same lookup rule and
does not hardcode a machine list.

Debian and Ubuntu recover `minkipc-qteesupplicant` and `xtest-qtee` from the
Qualcomm `qli-staging` trixie suite. Yocto, CentOS, and other distributions use
their image-provided components.

## Usage

Run all QTEE-applicable PKCS#11 cases at the baseline level:

```sh
./run.sh
```

Run selected test IDs or exclude a test:

```sh
./run.sh 1000 1003 1022
./run.sh -x 1026
```

Run optional higher-level coverage:

```sh
./run.sh --level 15
```

Select a TEE and override the timeout:

```sh
./run.sh --tee 1 --timeout 2400
```

Run repeatability coverage without cleanup between iterations:

```sh
./run.sh --iterations 2
```

Storage cleanup is evaluated only before the first iteration. Every iteration
must independently pass the complete result and expected-case validation.

Use `./run.sh --help` for the complete wrapper interface.

## Storage cleanup

The runner checks for both upstream storage test TAs before attempting
`xtest_qtee --clear-storage`. Source inspection shows that this applet stops at
the first TA it cannot open and clears only the REE and RPMB object namespaces
owned by those storage test TAs. It does not clear the PKCS#11 TA namespace.

Qualcomm QTEE images may provision only the PKCS#11 TA and omit the upstream
storage test TAs. In that configuration the runner skips the inapplicable
applet instead of invoking it and reporting an expected open-session error.
PKCS#11 case 1003 reinitializes its test token, and the object tests remove
their own persistent test objects. Use `--no-clear-storage` when the pre-run
applet must be suppressed explicitly even if both storage test TAs are present.

## Result policy

The run passes only when:

- `xtest_qtee` exits with status zero.
- The summary reports zero failed test cases and zero failed subtests.
- At least one case runs for a filtered invocation.
- Every expected QTEE PKCS#11 case reports `OK` in an unfiltered invocation.
- The shared kernel-log scanner finds no relevant QCOMTEE or RPMB errors.

The Qualcomm build exposes 21 PKCS#11 cases. The meta-qcom QTEE guard omits
upstream cases 1016, 1018, 1019, 1021, 1025, 1026, 1027, and 1028. The guard
starts before the shared RSA-AES support used by 1026 and ends after 1027, so
1026 is also absent from the QTEE binary.

Newer upstream optee_test revisions add cases 1029 for object checksums and
1030 for AES-GCM. They are not part of the optee_test 4.0.0 source integrated
by meta-qcom and should be evaluated when that dependency is upgraded.

## Related validation

- `MinkIPC_PKCS11_Multi_Client_Validation` runs safe discovery and session
  cases from multiple clients and validates recovery from QTEE TA contention.

Persistent-object validation across a `qtee_supplicant` restart remains future
work because it requires a helper that can intentionally leave a uniquely
labelled token object and reopen it in a later process.
