# Remoteproc validation

`remoteproc` is the unified passive health test for all registered remote
processors. It replaces the separate PIL remoteproc smoke test because both
tests inspected the same runtime remoteproc state.

The suite validates required sysfs attributes and accepts the Linux remoteproc
states `running`, `suspended`, `attached`, `offline`, and `detached`. It rejects
`crashed`, transient removal, and unknown states, records the bound driver,
checks image-provided firmware when it is exposed, and captures relevant
remoteproc and Qualcomm PAS kernel errors. This generic inventory includes
SOCCP automatically whenever the running target registers it.

Kernel-log validation is skipped, with an evidence path, when the target does
not permit kernel-log access. A registered remoteproc with incomplete sysfs
attributes, a crashed state, an unknown state, or a matching kernel error is a
failure.

The test does not start, stop, or reset a remote processor. SMP2P remains a
separate suite because it validates SMEM edge configuration, doorbell routing,
interrupt registration, and the `qcom_smp2p` driver.
