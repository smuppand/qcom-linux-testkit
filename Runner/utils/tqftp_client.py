#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Run one bounded read-only TQFTP transfer over AF_QIPCRTR."""

import argparse
import hashlib
import socket
import struct
import sys
from pathlib import Path


DEFAULT_BLOCK_SIZE = 512
MAX_PACKET_LOGS = 16


def fail(reason: str, **fields: object) -> int:
    """Print one machine-readable failure record and return failure status."""
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    print(f"TQFTP_E2E status=FAIL reason={reason} {details}".rstrip())
    return 1


def parse_oack(payload: bytes):
    """Parse and validate the numeric option pairs in a TFTP OACK payload."""
    fields = payload.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % 2:
        raise ValueError("odd option field count")

    options = {}
    for index in range(0, len(fields), 2):
        key = fields[index].decode("ascii").lower()
        value = fields[index + 1].decode("ascii")
        if not key or not value or not value.isdigit():
            raise ValueError("invalid option pair")
        if key in options:
            raise ValueError("duplicate option")
        options[key] = int(value)
    return options


def main() -> int:
    """Run one bounded RRQ transfer and verify the received file exactly."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--remote-path", required=True)
    parser.add_argument("--expected-file", type=Path, required=True)
    parser.add_argument("--output-file", type=Path, required=True)
    parser.add_argument("--timeout", type=float, required=True)
    args = parser.parse_args()

    family = getattr(socket, "AF_QIPCRTR", 42)

    try:
        expected = args.expected_file.read_bytes()
    except OSError as error:
        return fail("expected-file-read", errno=error.errno, message=str(error))
    expected_size = len(expected)
    request = (
        struct.pack("!H", 1)
        + args.remote_path.encode()
        + b"\0octet\0"
        + b"blksize\0"
        + str(DEFAULT_BLOCK_SIZE).encode()
        + b"\0wsize\0"
        + b"1\0rsize\0"
        + str(expected_size).encode()
        + b"\0"
    )
    received = bytearray()
    expected_block = 1
    packet_count = 0
    data_packet_count = 0
    packet_logs = 0
    oack_received = False
    negotiated_block_size = DEFAULT_BLOCK_SIZE
    negotiated_read_size = 0
    negotiated_window_size = 0
    transfer_port = "unknown"
    transfer_source = None

    try:
        with socket.socket(family, socket.SOCK_DGRAM) as client:
            client.settimeout(args.timeout)
            client.sendto(request, (args.node, args.port))
            while True:
                packet, source = client.recvfrom(65536)
                packet_count += 1
                if len(packet) < 2:
                    return fail("short-packet", packet_bytes=len(packet))
                opcode = struct.unpack("!H", packet[:2])[0]
                transfer_port = source[1]
                if transfer_source is None:
                    transfer_source = source
                elif source != transfer_source:
                    return fail(
                        "transfer-source-changed",
                        expected_source=transfer_source,
                        observed_source=source,
                    )
                if opcode == 5:
                    if len(packet) < 4:
                        return fail("short-error-packet", packet_bytes=len(packet))
                    block = struct.unpack("!H", packet[2:4])[0]
                    message = packet[4:].split(b"\0", 1)[0].decode(errors="replace")
                    return fail("server-error", code=block, message=message)
                if opcode == 6:
                    if oack_received or data_packet_count:
                        return fail("unexpected-oack", packets=packet_count)
                    try:
                        options = parse_oack(packet[2:])
                    except (UnicodeDecodeError, ValueError) as error:
                        return fail("invalid-oack", message=str(error))
                    negotiated_block_size = options.get("blksize", 0)
                    negotiated_window_size = options.get("wsize", 0)
                    negotiated_read_size = options.get("rsize", 0)
                    if negotiated_block_size != DEFAULT_BLOCK_SIZE:
                        return fail(
                            "unexpected-oack-blksize",
                            expected=DEFAULT_BLOCK_SIZE,
                            observed=negotiated_block_size,
                        )
                    if negotiated_window_size != 1:
                        return fail(
                            "unexpected-oack-wsize",
                            expected=1,
                            observed=negotiated_window_size,
                        )
                    if negotiated_read_size != expected_size:
                        return fail(
                            "unexpected-oack-rsize",
                            expected=expected_size,
                            observed=negotiated_read_size,
                        )
                    oack_received = True
                    print(
                        "TQFTP_PACKET phase=oack"
                        f" source_node={source[0]} source_port={source[1]}"
                        f" blksize={negotiated_block_size}"
                        f" wsize={negotiated_window_size}"
                        f" rsize={negotiated_read_size}"
                    )
                    client.sendto(struct.pack("!HH", 4, 0), source)
                    continue
                if opcode != 3:
                    return fail("unexpected-opcode", opcode=opcode)
                if not oack_received:
                    return fail("data-before-oack", packets=packet_count)
                if len(packet) < 4:
                    return fail("short-data-packet", packet_bytes=len(packet))
                block = struct.unpack("!H", packet[2:4])[0]
                if block != expected_block:
                    return fail(
                        "unexpected-block",
                        expected_block=expected_block,
                        observed_block=block,
                    )
                payload = packet[4:]
                received.extend(payload)
                data_packet_count += 1
                if packet_logs < MAX_PACKET_LOGS:
                    print(
                        "TQFTP_PACKET phase=data"
                        f" block={block} payload_bytes={len(payload)}"
                        f" cumulative_bytes={len(received)}"
                        f" source_node={source[0]} source_port={source[1]}"
                    )
                    packet_logs += 1
                client.sendto(struct.pack("!HH", 4, block), source)
                expected_block = (expected_block + 1) & 0xFFFF
                if len(received) >= expected_size:
                    break
    except TimeoutError:
        return fail(
            "transfer-timeout",
            packets=packet_count,
            data_packets=data_packet_count,
            expected_block=expected_block,
            received_bytes=len(received),
            expected_bytes=expected_size,
            oack=int(oack_received),
            transfer_port=transfer_port,
        )
    except OSError as error:
        return fail("socket-error", errno=error.errno, message=str(error))

    try:
        args.output_file.write_bytes(received)
    except OSError as error:
        return fail("output-file-write", errno=error.errno, message=str(error))
    expected_digest = hashlib.sha256(expected).hexdigest()
    received_digest = hashlib.sha256(received).hexdigest()
    if received != expected:
        return fail(
            "payload-mismatch",
            expected_bytes=len(expected),
            received_bytes=len(received),
            expected_sha256=expected_digest,
            received_sha256=received_digest,
        )

    if data_packet_count > packet_logs:
        print(
            "TQFTP_PACKET phase=data-summary"
            f" omitted={data_packet_count - packet_logs}"
            f" total_data_packets={data_packet_count}"
        )

    print(
        "TQFTP_E2E status=PASS"
        f" server_node={args.node} service_port={args.port}"
        f" transfer_port={transfer_port} request_bytes={len(request)}"
        f" packets={packet_count} data_packets={data_packet_count}"
        f" blksize={negotiated_block_size} wsize={negotiated_window_size}"
        f" rsize={negotiated_read_size} received_bytes={len(received)}"
        f" sha256={received_digest} payload=verified"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
