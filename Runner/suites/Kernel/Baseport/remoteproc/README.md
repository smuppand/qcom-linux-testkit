# Remoteproc validation

`remoteproc` is the unified passive health test for all registered remote
processors. It replaces the separate PIL remoteproc smoke test because both
tests inspected the same runtime remoteproc state.

The suite validates required sysfs attributes, accepts valid `running`,
`attached`, and non-autoboot `offline` states, rejects `crashed` states,
records the bound driver, checks image-provided firmware when it is exposed,
and captures relevant remoteproc and Qualcomm PAS kernel errors.

The test does not start, stop, or reset a remote processor. SMP2P remains a
separate suite because it validates SMEM edge configuration, doorbell routing,
interrupt registration, and the `qcom_smp2p` driver.
