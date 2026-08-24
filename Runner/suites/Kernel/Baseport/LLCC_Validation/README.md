# Qualcomm LLCC validation

`LLCC_Validation` checks runtime applicability and driver registration for the
Qualcomm Last Level Cache Controller. It dynamically discovers enabled
`qcom,*-llcc` nodes and verifies that their platform devices bind to the
upstream `qcom-llcc` driver.

The test also records `CONFIG_QCOM_LLCC` when the running kernel configuration
is available and captures LLCC-related kernel errors through the shared dmesg
scanner.

The suite does not assume that an LLCC performance-monitoring unit exists and
does not access LLCC registers. ECC reporting is covered separately by
`QCOM_EDAC_Validation` because some LLCC configurations intentionally disable
the EDAC child device.

The suite returns `SKIP` when no enabled LLCC node is present.
