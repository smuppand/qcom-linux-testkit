# CAN internal loopback validation

`CAN_Internal_Loopback_Validation` sends and receives exact SocketCAN frames
through an auto-detected or explicitly selected physical CAN controller in
internal-loopback mode.

For safety, the suite requires each interface to be initially down. It configures
each selected interface with a default 500 kbit/s arbitration bitrate and a
2 Mbit/s CAN FD data bitrate. An active CAN interface is never taken over
automatically. Every physical interface meeting these readiness conditions is
selected automatically and validated sequentially.

The suite restores the interface to down and restores the original bitrate,
data bitrate, CAN FD, and loopback settings when they were initially exposed.
Linux does not provide a portable operation to return a previously unconfigured
physical CAN interface to an unconfigured timing state. In that case the test
leaves the interface down with the test bitrate configured and reports that
state in stdout.

Classic mode validates both an 11-bit identifier and a 29-bit extended
identifier. Automatic mode attempts a CAN-FD frame using the default data
bitrate and records a clean skip when the controller rejects CAN FD. Every case
requires RX and TX packet counters to increase and error counters not to
increase when sysfs exposes those counters.

## Prepare and run

Run automatic CAN loopback with the default bitrates:

```sh
cd Runner/suites/Kernel/Baseport/CAN_Internal_Loopback_Validation
./run.sh
```

Override the selected interface or timing when required:

```sh
./run.sh --interface can0 --mode auto --bitrate 500000 --dbitrate 2000000
```

Use `--interface` or `CAN_INTERFACE` to override automatic discovery.
`CAN_BITRATE` and `CAN_DBITRATE` override the timing defaults. CLI options take
precedence over environment variables.

With no override, the suite discovers and sequentially validates every down
physical CAN interface. Use `--interface` or `CAN_INTERFACE` to restrict
validation to one interface. The test uses image-provided `ip`, `candump`, and
`cansend` only and skips cleanly when those optional utilities are absent.

Command and frame evidence is retained under
`results/CAN_Internal_Loopback_Validation/run-*/<interface>/`. The
live log retains the per-object failure analysis needed for remote debugging.

## Result policy

- `PASS`: all applicable exact frames are observed, packet counters increase,
  error counters remain stable, and state restoration succeeds.
- `FAIL`: the selected object is not physical CAN hardware, configuration,
  transfer, frame validation, or restoration fails.
- `SKIP`: no ready physical interface is discovered, required image-provided
  tools are absent, or CAN FD is unavailable during automatic mode.

Reference: [Qualcomm Linux CAN guide](https://docs.qualcomm.com/doc/80-70023-8/topic/can.html)
