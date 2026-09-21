# Native OP-TEE validation

`OPTEE_Native_Validation` is separate from the Qualcomm MinkIPC and
`xtest_qtee` suites. It applies only when the Linux TEE class exposes a native
OP-TEE device and the image provides the upstream `xtest` client.

There is no generic replacement for `xtest`: its client and matching test TAs
define the functional contract. A direct TEE ioctl probe would prove only ABI
access, and Qualcomm MinkIPC exercises a different stack. Therefore an image
without compatible `xtest` assets skips rather than reporting weaker readiness
as native OP-TEE functional success.

No SoC-specific device path is required. The suite prefers the optional
`/sys/class/tee/*/impl_id` evidence and falls back to the bound OP-TEE parent
driver or resolved sysfs path only when that attribute is unreadable. A
readable non-OP-TEE implementation ID is authoritative and is never overridden
by path heuristics. The
`[OPTEE-DISCOVERY]` line identifies the selected source as `impl-id`,
`runtime-driver`, or `runtime-path`. Every
functional invocation passes the public `optee-tz` TEE identifier to `xtest`,
which makes `libteec` verify `TEE_IOC_VERSION`, the OP-TEE implementation ID,
and TrustZone capability before opening the context. The default cases are the
same reviewed upstream regression cases on every applicable target; users
normally do not need to override them.

The automation is intentionally restricted to the reviewed level-zero
regression cases:

- `1001`: core self tests
- `1002`: PTA parameter transfer

No storage clearing, persistent-object, RPMB, install-TA, performance, panic,
or broad full-suite operation is accepted. A CLI override can select a subset
of the built-in allowlist but cannot add arbitrary cases.

Use `--xtest` only when an image installs the upstream client under a
nonstandard path. Use `--cases` only to reduce the safe default subset for a
specific test plan, not to encode a SoC-specific case list.

## Run

```sh
./run.sh
./run.sh --cases 1001 --timeout 45
```

| Option | Environment | Default |
|---|---|---:|
| `--xtest` | `OPTEE_XTEST_BIN` | `xtest` |
| `--cases` | `OPTEE_XTEST_CASES` | `1001,1002` |
| `--timeout` | `OPTEE_XTEST_TIMEOUT` | `30` seconds per case |

The suite requires both a zero command status and an explicit zero-failure
`xtest` summary. An `xtest`-reported optional-PTA skip remains a subcheck skip.
Look for `[OPTEE-POLICY]`, `[OPTEE-DEVICE]`, `[OPTEE-DISCOVERY]`, and
`[OPTEE-XTEST]`. Device inventory is printed before applicability is classified,
including public versus private class nodes, optional `impl_id`, parent driver,
resolved path, capabilities, device node, and character-device state. Per-case summary markers are replayed to
stdout, while failed case logs are shown as a bounded excerpt. Per-case
logs and kernel evidence are retained under
`results/OPTEE_Native_Validation/run-*/`.

Kernel health capture prefers `dmesg` and falls back to image-provided
`journalctl -k`; `kernel/dmesg_access.log` retains provider and permission
diagnostics.
