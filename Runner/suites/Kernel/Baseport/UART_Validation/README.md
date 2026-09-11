# UART validation

`UART_Validation` performs read-only functional-readiness validation of enabled
UART controllers and their Linux runtime consumers. It does not assume a fixed
serial-engine address, alias, TTY number, board, or SoC.

The suite correlates:

- Enabled runtime DT nodes named `serial@...` or `uart@...`
- Platform-device and driver binding
- Physical TTY class devices
- Active serial-console ownership from `/proc/consoles`
- Bound serdev consumers such as Bluetooth devices

An enabled controller is healthy when it has a bound controller driver and is
consumed by either a TTY or a bound serdev child. A serdev-owned controller is
not incorrectly required to expose a user-accessible TTY.

## Run

```sh
cd Runner/suites/Kernel/Baseport/UART_Validation
./run.sh
```

## Result policy

- `PASS`: discovered UART controllers and consumers are consistently bound.
- `FAIL`: an enabled controller lacks its platform device, driver, TTY, or
  bound serdev consumer, a Bluetooth serdev lacks its HCI adapter, an available
  HCI control probe fails, or persistent UART kernel errors are present.
- `SKIP`: no enabled or runtime-visible UART capability exists.

## Diagnostics

The suite emits bounded per-object binding, consumer, and kernel-health
diagnostics to stdout. Evidence is retained under
`results/UART_Validation/run-*/`.

Bluetooth-owned UARTs are validated without opening their TTY directly. The
suite correlates each bound Bluetooth serdev consumer with its runtime HCI
adapter and runs a bounded `btmgmt`, `hciconfig`, or `bluetoothctl` control
probe when one is image-provided. A declared and bound Bluetooth serdev with no
corresponding HCI adapter fails. If no control utility is available, the bound
serdev-to-HCI registration remains the kernel transport evidence and the
missing optional probe is reported in stdout.

Physical data transfer is intentionally kept out of this evidence suite.
Loopback must use an explicitly selected non-console UART and must restore its
termios state.

Reference: [Qualcomm Linux UART guide](https://docs.qualcomm.com/doc/80-70023-8/topic/uart.html)
