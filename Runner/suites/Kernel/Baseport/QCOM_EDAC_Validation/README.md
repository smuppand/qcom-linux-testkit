# Qualcomm LLCC EDAC validation

`QCOM_EDAC_Validation` validates the upstream Qualcomm LLCC EDAC child device
and its read-only bank counters under:

```text
/sys/devices/system/edac/qcom-llcc/
```

The Qualcomm driver reports single-bit and double-bit errors for LLCC tag and
data RAM. Depending on platform configuration it operates through an ECC IRQ
or periodic polling.

## Options

```text
--strict-ce 0|1
--observe-seconds N
```

The equivalent LAVA environment variables are `STRICT_CE` and
`OBSERVE_SECONDS`. Command-line values take precedence.

Uncorrectable errors, increasing UE counters, missing counters, or an exposed
but unbound EDAC device fail the test. Existing or increasing CE counters are
warnings by default and failures with `--strict-ce 1`.

The suite returns `SKIP` when the LLCC driver does not create an EDAC child.
This is valid on platforms where EDAC register access is intentionally
disabled. The test never injects errors and never writes EDAC or LLCC
registers.
