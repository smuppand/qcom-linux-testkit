# SMP2P validation

`SMP2P_Validation` validates the upstream Qualcomm Shared Memory Point to
Point driver integration. SMP2P transports state between HLOS and remote
processors through SMEM and an IPC doorbell, and is used by remoteproc stop
and restart flows.

The suite is passive by design. It does not write SMEM state, enable tracing,
trigger an interrupt, or start, stop, or reset a remote processor.

## Coverage

The test runs only when an enabled `qcom,smp2p` node is present in the runtime
device tree. It validates:

- `CONFIG_QCOM_SMP2P` is enabled.
- Required edge properties: `qcom,smem`, `qcom,local-pid`, and
  `qcom,remote-pid`. Interrupt routing is validated through `interrupts` or
  `interrupts-extended` when exposed by DT, otherwise through a bound driver
  and registered SMP2P interrupt.
- An outgoing doorbell is described using `mboxes` or legacy `qcom,ipc`.
- Each child entry has `qcom,entry-name` and is either an inbound interrupt
  controller or an outbound SMEM state provider.
- A runtime platform device is bound to the `qcom_smp2p` driver.
- SMP2P interrupt and upstream tracepoint exposure, when the kernel exposes
  them.
- Captured SMP2P and SMEM kernel log health through `scan_dmesg_errors`.

For LAVA triage, stdout includes the matched kernel-config line, resolved
bound-device sysfs paths, matching `/proc/interrupts` lines, and a readable
preview plus exact hexadecimal bytes for relevant DT properties. The same
runtime evidence is retained in `smp2p_devices.log`, `smp2p_interrupts.log`,
and `smp2p_nodes.log` beside the test result.

If the platform does not describe SMP2P hardware, the suite returns `SKIP`.

## Future functional coverage

The upstream driver has no stable user-space interface for reading or writing
an arbitrary SMP2P entry. A functional test therefore must be tied to a
specific remote processor and must restore its original state.

The appropriate follow-up is a separate opt-in SSR handshake suite. It can
snapshot tracefs and remoteproc state, restart a user-selected non-critical
remote processor, capture `smp2p_negotiate`, `smp2p_ssr_ack`,
`smp2p_notify_in`, and `smp2p_update_bits`, then restore tracing and the
processor state. It must not be part of this default passive suite because it
can interrupt DSP, modem, or audio services.
