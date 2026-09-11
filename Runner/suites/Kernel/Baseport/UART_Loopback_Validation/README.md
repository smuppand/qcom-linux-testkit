# UART loopback validation

`UART_Loopback_Validation` verifies exact payload transfer through an
auto-detected or explicitly selected UART. It supports controller-internal
loopback through `TIOCM_LOOP` and an external return path provided by TX-to-RX
wiring or a USB-to-UART peer that echoes the transmitted bytes.

The suite refuses active kernel consoles, snapshots the complete termios state,
uses bounded reads and writes, compares a 4 KiB transmitted and received
payload, exercises requested baud and character-width combinations, and
restores the saved state after every case. In internal mode, every accessible,
unused, DT-backed physical non-console UART is selected and validated
sequentially. In external mode, automatic selection still requires exactly one
eligible UART because CI cannot infer which physical port is connected to the
intended fixture or peer. Generic legacy `ttyS*` entries without runtime DT
ownership are ignored.

Before changing termios, the suite also compares the selected device with its
own stdin, stdout, and stderr and scans current userspace file-descriptor
owners. A serial shell, getty, or another process holding that UART produces a
safe `SKIP` with the dynamically discovered owner PID, command, and FD in the
live log.

Automatic baud selection uses the portable `115200` default. Specify any
additional board-qualified baud rates explicitly with `--baud` or
`UART_BAUDS`.

## Run

```sh
cd Runner/suites/Kernel/Baseport/UART_Loopback_Validation
./run.sh --fixture
```

This runs external loopback and therefore requires a confirmed return path,
such as TX-to-RX wiring or a USB-to-UART peer echo process. The `--fixture`
option confirms that this external path exists; it does not create an echo.
For the controller-internal test equivalent to `msm_uart_test -l`, run:

```sh
./run.sh --loopback internal
```

Internal mode uses image-provided `python3` to issue `TIOCMGET` and `TIOCMSET`,
enable `TIOCM_LOOP`, configure and transfer through one open file descriptor,
and restore the original modem-control bits and termios state. It skips cleanly
when Python or the UART driver's loopback ioctl is unavailable.

For migration from `msm_uart_test`, the focused loopback suite also accepts
`-l`, `-d`, `-b`, `-s`, `-f`, and `-c`. For example:

```sh
./run.sh -l -d /dev/ttyHS2 -b 115200 -s 400 -f 1 -c 8
```

The legacy nominal mode is not copied because it does not verify received
data. The interactive echo mode is also excluded from unattended CI because
success depends on an external peer and manual interruption.

`UART_DEVICE` defaults to empty, causing `run.sh` to discover the device from
runtime sysfs and device-tree evidence. Internal mode tests all eligible
devices sequentially. Setting `UART_DEVICE` or `--device` restricts either mode
to that one device. Baud, data bits, flow control, payload size, and timeout
retain their documented defaults.

Optional settings:

```sh
./run.sh --fixture --baud 115200,921600,3000000 \
    --data-bits 7,8 --flow-control none --payload-bytes 4096 --timeout 15
```

Use `--device /dev/<runtime-device>` to restrict internal mode to one UART, or
when external mode finds multiple safe UARTs and the return path is attached to
a specific port.

Use `--device` or `UART_DEVICE` to override automatic discovery. CLI options
take precedence over environment variables. Other environment variables are
`UART_BAUDS`, `UART_DATA_BITS`, `UART_FLOW_CONTROL`, `UART_PAYLOAD_BYTES`,
`UART_LOOPBACK_TYPE`, `UART_LOOPBACK_TIMEOUT`, and `UART_LOOPBACK_FIXTURE`. The
legacy single-value `UART_BAUD` environment variable remains supported.

An external return path must be explicitly confirmed with `--fixture` or
`UART_LOOPBACK_FIXTURE=1`. This prevents an unqualified test job from
transmitting on an auto-detected UART. Internal mode does not require this flag.

The default is 8 data bits with no hardware flow control. Character widths
5, 6, 7, and 8 are available through `--data-bits`. Selecting
`--flow-control rtscts` additionally requires RTS-to-CTS wiring in the fixture.
The suite does not require the proprietary `msm_uart_test` binary. Its probe,
configuration, bounded transfer, exact-data checks, and internal ioctl mode are
implemented using repository helpers and image-provided utilities.

Payload and command evidence is retained under
`results/UART_Loopback_Validation/run-*/`. Each selected UART has a separate
device-named subdirectory so evidence cannot be overwritten by a later case. The
live log records TX and RX byte counts, checksums, bounded 32-byte hexadecimal
previews, exact byte-for-byte comparison status, restoration evidence, and the
complete payload artifact paths.

Key live-log markers are:

- `[UART-PAYLOAD]`: direction, byte count, checksum, bounded preview, and file
- `[UART-INTERNAL] state=payload`: SHA-256 proof for internal TX and RX data
- `[UART-PROOF]`: final byte-for-byte comparison and complete artifact paths
- `[UART-RESTORE]`: final termios restoration result

## Result policy

- `PASS`: the exact payload is received and all changed state is restored.
- `FAIL`: the selected device is unsafe or invalid, configuration or transfer
  fails, bytes differ, a timeout occurs, or state restoration fails.
- `SKIP`: no safe UART is discovered, external mode has ambiguous multiple
  candidates without an override, or required utilities or the requested
  internal-loopback ioctl are absent.

Reference: [Qualcomm Linux UART guide](https://docs.qualcomm.com/doc/80-70023-8/topic/uart.html)
