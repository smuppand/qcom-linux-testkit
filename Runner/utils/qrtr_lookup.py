#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Bounded QRTR control-port service lookup using the public Linux ABI."""

import argparse
import socket
import struct
import sys


AF_QIPCRTR = getattr(socket, "AF_QIPCRTR", 42)
QRTR_PORT_CTRL = 0xFFFFFFFE
QRTR_TYPE_NEW_SERVER = 4
QRTR_TYPE_NEW_LOOKUP = 10
QRTR_DIAG_SERVICE = 4097
CTRL_PACKET = struct.Struct("<IIIII")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, default=2.0)
    return parser.parse_args()


def main():
    args = parse_args()
    if args.timeout <= 0:
        print("timeout must be positive", file=sys.stderr)
        return 2

    try:
        sock = socket.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    except OSError as error:
        print("AF_QIPCRTR socket failed: {}".format(error), file=sys.stderr)
        return 1

    with sock:
        sock.settimeout(args.timeout)
        try:
            local_node, _ = sock.getsockname()
            request = CTRL_PACKET.pack(QRTR_TYPE_NEW_LOOKUP, 0, 0, 0, 0)
            sock.sendto(request, (local_node, QRTR_PORT_CTRL))
        except (OSError, ValueError) as error:
            print("QRTR lookup request failed: {}".format(error), file=sys.stderr)
            return 1

        print("Service Version Instance Node Port")
        while True:
            try:
                payload = sock.recv(CTRL_PACKET.size)
            except socket.timeout:
                print("QRTR lookup response timed out", file=sys.stderr)
                return 1
            except OSError as error:
                print("QRTR lookup receive failed: {}".format(error), file=sys.stderr)
                return 1

            if len(payload) != CTRL_PACKET.size:
                continue
            command, service, packed_instance, node, port = CTRL_PACKET.unpack(payload)
            if command != QRTR_TYPE_NEW_SERVER:
                continue
            if service == 0 and packed_instance == 0 and node == 0 and port == 0:
                return 0

            if service == QRTR_DIAG_SERVICE:
                version = "N/A"
                instance = packed_instance
            else:
                version = packed_instance & 0xFF
                instance = packed_instance >> 8
            print("{} {} {} {} {}".format(service, version, instance, node, port))


if __name__ == "__main__":
    sys.exit(main())
