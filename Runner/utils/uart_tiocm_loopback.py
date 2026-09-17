#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
"""Run a bounded UART controller-internal loopback through TIOCM_LOOP."""

import argparse
import array
import errno
import fcntl
import hashlib
import os
import select
import signal
import sys
import termios
import time


TIOCMGET = getattr(termios, "TIOCMGET", 0x5415)
TIOCMSET = getattr(termios, "TIOCMSET", 0x5418)
TIOCM_LOOP = getattr(termios, "TIOCM_LOOP", 0x8000)
UNSUPPORTED_ERRNOS = {
    errno.EINVAL,
    errno.ENOSYS,
    errno.ENOTTY,
    errno.EOPNOTSUPP,
}


class InterruptedRun(Exception):
    """Raised when the timeout wrapper asks the helper to terminate."""


class UnsupportedOperation(Exception):
    """Raised when the runtime cannot provide a requested UART operation."""


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    parser.add_argument("--tx-file", required=True)
    parser.add_argument("--rx-file", required=True)
    parser.add_argument("--timeout", required=True, type=int)
    parser.add_argument("--baud", required=True, type=int)
    parser.add_argument("--data-bits", required=True, type=int)
    parser.add_argument("--flow-control", choices=("none", "rtscts"), required=True)
    return parser.parse_args()


def get_modem_bits(fd):
    bits = array.array("i", [0])
    fcntl.ioctl(fd, TIOCMGET, bits, True)
    return bits[0]


def set_modem_bits(fd, value):
    bits = array.array("i", [value])
    fcntl.ioctl(fd, TIOCMSET, bits)


def interrupted(_signum, _frame):
    raise InterruptedRun("terminated-by-timeout-wrapper")


def log_payload(direction, payload):
    print(
        "state=payload direction=%s bytes=%d sha256=%s preview_hex=%s preview_bytes=%d"
        % (
            direction,
            len(payload),
            hashlib.sha256(payload).hexdigest(),
            payload[:32].hex(),
            min(len(payload), 32),
        )
    )


def configure_uart(fd, baud, data_bits, flow_control):
    speed = getattr(termios, "B%d" % baud, None)
    if speed is None:
        raise UnsupportedOperation("baud-%d-not-exposed-by-python-termios" % baud)

    character_sizes = {
        5: termios.CS5,
        6: termios.CS6,
        7: termios.CS7,
        8: termios.CS8,
    }
    if data_bits not in character_sizes:
        raise UnsupportedOperation("data-bits-%d-unsupported" % data_bits)

    hardware_flow = getattr(termios, "CRTSCTS", None)
    if flow_control == "rtscts" and hardware_flow is None:
        raise UnsupportedOperation("CRTSCTS-not-exposed-by-python-termios")

    original_attributes = termios.tcgetattr(fd)
    attributes = original_attributes[:]
    attributes[6] = original_attributes[6][:]
    attributes[0] = termios.IGNPAR
    attributes[1] = 0
    attributes[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)
    attributes[2] |= character_sizes[data_bits] | termios.CLOCAL | termios.CREAD
    if hardware_flow is not None:
        if flow_control == "rtscts":
            attributes[2] |= hardware_flow
        else:
            attributes[2] &= ~hardware_flow
    attributes[3] = 0
    attributes[4] = speed
    attributes[5] = speed
    attributes[6][termios.VMIN] = 0
    attributes[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attributes)

    current_flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, current_flags & ~os.O_NONBLOCK)
    return original_attributes


def transfer(fd, payload, timeout_seconds):
    received = bytearray()
    written = 0
    deadline = time.monotonic() + timeout_seconds

    while written < len(payload) or len(received) < len(payload):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                "transfer-timeout written=%d received=%d expected=%d"
                % (written, len(received), len(payload))
            )

        write_set = [fd] if written < len(payload) else []
        readable, writable, _exceptional = select.select(
            [fd], write_set, [], remaining
        )

        if fd in writable:
            try:
                count = os.write(fd, payload[written : written + 256])
            except BlockingIOError:
                count = 0
            if count > 0:
                written += count

        if fd in readable:
            try:
                chunk = os.read(fd, len(payload) - len(received))
            except BlockingIOError:
                chunk = b""
            if chunk:
                received.extend(chunk)

    return bytes(received), written


def main():
    args = parse_args()
    if args.timeout <= 0:
        print("state=invalid-argument reason=timeout-must-be-positive")
        return 1

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)

    fd = None
    original_bits = None
    original_termios = None
    restore_required = False
    received = b""
    status = 1

    try:
        with open(args.tx_file, "rb") as tx_stream:
            payload = tx_stream.read()
        if not payload:
            raise ValueError("transmit-payload-is-empty")
        log_payload("tx", payload)

        fd = os.open(
            args.device,
            os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0),
        )
        try:
            original_bits = get_modem_bits(fd)
        except OSError as exc:
            if exc.errno in UNSUPPORTED_ERRNOS:
                print(
                    "state=unsupported operation=TIOCMGET errno=%d error=%s"
                    % (exc.errno, exc.strerror)
                )
                status = 2
            else:
                raise
        else:
            preexisting = "yes" if original_bits & TIOCM_LOOP else "no"
            print(
                "state=precheck modem_bits=0x%x loop_preexisting=%s"
                % (original_bits, preexisting)
            )
            try:
                set_modem_bits(fd, original_bits | TIOCM_LOOP)
                restore_required = True
                enabled_bits = get_modem_bits(fd)
            except OSError as exc:
                if exc.errno in UNSUPPORTED_ERRNOS:
                    print(
                        "state=unsupported operation=TIOCM_LOOP errno=%d error=%s"
                        % (exc.errno, exc.strerror)
                    )
                    status = 2
                else:
                    raise
            else:
                readback = "set" if enabled_bits & TIOCM_LOOP else "not-exposed"
                print(
                    "state=enabled modem_bits=0x%x loop_readback=%s"
                    % (enabled_bits, readback)
                )
                original_termios = configure_uart(
                    fd,
                    args.baud,
                    args.data_bits,
                    args.flow_control,
                )
                print(
                    "state=configured baud=%d data_bits=%d flow_control=%s blocking=yes"
                    % (args.baud, args.data_bits, args.flow_control)
                )
                termios.tcflush(fd, termios.TCIOFLUSH)
                received, written = transfer(fd, payload, args.timeout)
                if received != payload:
                    raise RuntimeError(
                        "payload-mismatch written=%d received=%d expected=%d"
                        % (written, len(received), len(payload))
                    )
                print(
                    "state=transfer-complete written=%d received=%d comparison=byte-for-byte-match"
                    % (written, len(received))
                )
                status = 0
    except UnsupportedOperation as exc:
        print("state=unsupported operation=termios error=%s" % str(exc))
        status = 2
    except (InterruptedRun, OSError, RuntimeError, TimeoutError, ValueError) as exc:
        print("state=failed error=%s" % str(exc))
        status = 1
    finally:
        log_payload("rx", received)
        try:
            with open(args.rx_file, "wb") as rx_stream:
                rx_stream.write(received)
        except OSError as exc:
            print("state=failed operation=write-rx-artifact error=%s" % str(exc))
            status = 1

        if fd is not None and original_bits is not None and restore_required:
            try:
                set_modem_bits(fd, original_bits)
                restored_bits = get_modem_bits(fd)
                if (restored_bits & TIOCM_LOOP) != (original_bits & TIOCM_LOOP):
                    raise RuntimeError(
                        "TIOCM_LOOP-restore-readback-mismatch expected=0x%x observed=0x%x"
                        % (original_bits, restored_bits)
                    )
                print(
                    "state=restored original_modem_bits=0x%x observed_modem_bits=0x%x loop_bit=matched"
                    % (original_bits, restored_bits)
                )
            except (OSError, RuntimeError) as exc:
                print("state=restore-failed error=%s" % str(exc))
                status = 1

        if fd is not None and original_termios is not None:
            try:
                termios.tcsetattr(fd, termios.TCSANOW, original_termios)
                print("state=termios-restored verification=tcsetattr-success")
            except OSError as exc:
                print("state=termios-restore-failed error=%s" % str(exc))
                status = 1

        if fd is not None:
            os.close(fd)

    return status


if __name__ == "__main__":
    sys.exit(main())
