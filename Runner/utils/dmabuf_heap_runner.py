#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Exercise the public Linux DMA-HEAP and DMA-BUF CPU-access UAPI."""

import argparse
import errno
import fcntl
import hashlib
import mmap
import os
import stat
import struct
import sys


IOC_NRBITS = 8
IOC_TYPEBITS = 8
IOC_SIZEBITS = 14
IOC_NRSHIFT = 0
IOC_TYPESHIFT = IOC_NRSHIFT + IOC_NRBITS
IOC_SIZESHIFT = IOC_TYPESHIFT + IOC_TYPEBITS
IOC_DIRSHIFT = IOC_SIZESHIFT + IOC_SIZEBITS
IOC_WRITE = 1
IOC_READ = 2

DMA_HEAP_ALLOCATION_FORMAT = "=QIIQ"
DMA_BUF_SYNC_FORMAT = "=Q"
DMA_HEAP_IOCTL_ALLOC = (
    ((IOC_READ | IOC_WRITE) << IOC_DIRSHIFT)
    | (ord("H") << IOC_TYPESHIFT)
    | (0 << IOC_NRSHIFT)
    | (struct.calcsize(DMA_HEAP_ALLOCATION_FORMAT) << IOC_SIZESHIFT)
)
DMA_BUF_IOCTL_SYNC = (
    (IOC_WRITE << IOC_DIRSHIFT)
    | (ord("b") << IOC_TYPESHIFT)
    | (0 << IOC_NRSHIFT)
    | (struct.calcsize(DMA_BUF_SYNC_FORMAT) << IOC_SIZESHIFT)
)
DMA_BUF_SYNC_READ = 1
DMA_BUF_SYNC_WRITE = 2
DMA_BUF_SYNC_END = 4
MAX_ALLOCATION_BYTES = 16 * 1024 * 1024


# write_report(path, report)
# Replaces PATH with a stable two-column TSV representation of REPORT. It has
# no return value and creates the parent directory when required.
def write_report(path, report):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as report_file:
        report_file.write("key\tvalue\n")
        for key, value in report.items():
            report_file.write(str(key) + "\t" + str(value) + "\n")


# count_open_fds()
# Returns the number of descriptors visible in /proc/self/fd, or -1 when procfs
# is unavailable. It emits no output and has no persistent side effects.
def count_open_fds():
    try:
        return len(os.listdir("/proc/self/fd"))
    except OSError:
        return -1


# sync_buffer(buffer_fd, flags)
# Issues DMA_BUF_IOCTL_SYNC for BUFFER_FD with one unsigned 64-bit FLAGS value.
# It returns no value, emits no output, and raises OSError on an ioctl failure.
def sync_buffer(buffer_fd, flags):
    request = bytearray(struct.pack(DMA_BUF_SYNC_FORMAT, flags))
    fcntl.ioctl(buffer_fd, DMA_BUF_IOCTL_SYNC, request, True)


# allocate_buffer(heap_fd, length)
# Allocates LENGTH bytes from an open DMA heap and returns the DMA-BUF fd. It
# requests read/write plus close-on-exec access and raises OSError on failure.
def allocate_buffer(heap_fd, length):
    fd_flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
    request = bytearray(
        struct.pack(
            DMA_HEAP_ALLOCATION_FORMAT,
            length,
            0,
            fd_flags,
            0,
        )
    )
    fcntl.ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, request, True)
    returned_length, buffer_fd, returned_flags, heap_flags = struct.unpack(
        DMA_HEAP_ALLOCATION_FORMAT,
        request,
    )
    if returned_length != length:
        raise RuntimeError(
            "DMA_HEAP_IOCTL_ALLOC changed length from "
            + str(length)
            + " to "
            + str(returned_length)
        )
    if returned_flags != fd_flags or heap_flags != 0:
        raise RuntimeError("DMA_HEAP_IOCTL_ALLOC returned unexpected flags")
    try:
        os.fstat(buffer_fd)
    except OSError as error:
        raise RuntimeError(
            "DMA_HEAP_IOCTL_ALLOC returned an unusable fd: " + str(error)
        ) from error
    return buffer_fd


# verify_closed_fd(buffer_fd)
# Confirms that BUFFER_FD is invalid after close. It returns True only for
# EBADF, emits no output, and has no side effects.
def verify_closed_fd(buffer_fd):
    try:
        os.fstat(buffer_fd)
    except OSError as error:
        return error.errno == errno.EBADF
    return False


# exercise_heap(heap_path, length, report)
# Opens HEAP_PATH, performs two bounded allocations, validates initial zeroing,
# mmap read/write integrity and DMA_BUF_IOCTL_SYNC bracketing, closes every map
# and fd, and updates REPORT. It returns no value and raises on any failure.
def exercise_heap(heap_path, length, report):
    baseline_fds = count_open_fds()
    heap_fd = -1
    first_fd = -1
    second_fd = -1
    first_map = None
    second_map = None
    first_sync_flags = 0
    second_sync_flags = 0
    first_closed = False
    second_closed = False

    pattern = bytes(((index * 37 + 11) & 0xFF) for index in range(length))
    expected_digest = hashlib.sha256(pattern).hexdigest()

    try:
        heap_fd = os.open(
            heap_path,
            os.O_RDWR | getattr(os, "O_CLOEXEC", 0),
        )
        first_fd = allocate_buffer(heap_fd, length)
        first_map = mmap.mmap(
            first_fd,
            length,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )

        first_sync_flags = DMA_BUF_SYNC_READ
        sync_buffer(first_fd, first_sync_flags)
        initially_zero = first_map[:] == bytes(length)
        sync_buffer(first_fd, first_sync_flags | DMA_BUF_SYNC_END)
        first_sync_flags = 0
        if not initially_zero:
            raise RuntimeError("new DMA-BUF allocation was not zero initialized")

        first_sync_flags = DMA_BUF_SYNC_WRITE
        sync_buffer(first_fd, first_sync_flags)
        first_map[:] = pattern
        sync_buffer(first_fd, first_sync_flags | DMA_BUF_SYNC_END)
        first_sync_flags = 0

        first_sync_flags = DMA_BUF_SYNC_READ
        sync_buffer(first_fd, first_sync_flags)
        observed = first_map[:]
        sync_buffer(first_fd, first_sync_flags | DMA_BUF_SYNC_END)
        first_sync_flags = 0
        observed_digest = hashlib.sha256(observed).hexdigest()
        if observed != pattern:
            raise RuntimeError(
                "DMA-BUF readback mismatch, expected_sha256="
                + expected_digest
                + " observed_sha256="
                + observed_digest
            )

        first_map.close()
        first_map = None
        os.close(first_fd)
        first_closed = verify_closed_fd(first_fd)
        if not first_closed:
            raise RuntimeError("first DMA-BUF fd remained valid after close")

        second_fd = allocate_buffer(heap_fd, length)
        second_map = mmap.mmap(
            second_fd,
            length,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )
        second_sync_flags = DMA_BUF_SYNC_READ
        sync_buffer(second_fd, second_sync_flags)
        second_zero = second_map[:] == bytes(length)
        sync_buffer(second_fd, second_sync_flags | DMA_BUF_SYNC_END)
        second_sync_flags = 0
        if not second_zero:
            raise RuntimeError("second DMA-BUF allocation was not zero initialized")

        second_map.close()
        second_map = None
        os.close(second_fd)
        second_closed = verify_closed_fd(second_fd)
        if not second_closed:
            raise RuntimeError("second DMA-BUF fd remained valid after close")

        os.close(heap_fd)
        heap_fd = -1
        final_fds = count_open_fds()
        if baseline_fds >= 0 and final_fds >= 0 and baseline_fds != final_fds:
            raise RuntimeError(
                "descriptor leak detected, before="
                + str(baseline_fds)
                + " after="
                + str(final_fds)
            )

        report["allocation_bytes"] = length
        report["allocations"] = 2
        report["maps"] = 2
        report["sync_transactions"] = 4
        report["pattern_sha256"] = expected_digest
        report["readback_sha256"] = observed_digest
        report["initial_zero"] = "yes"
        report["second_allocation_zero"] = "yes"
        report["first_fd_closed"] = "yes"
        report["second_fd_closed"] = "yes"
        report["fd_count_before"] = baseline_fds
        report["fd_count_after"] = final_fds
    finally:
        if first_sync_flags and first_fd >= 0:
            try:
                sync_buffer(first_fd, first_sync_flags | DMA_BUF_SYNC_END)
            except OSError:
                pass
        if second_sync_flags and second_fd >= 0:
            try:
                sync_buffer(second_fd, second_sync_flags | DMA_BUF_SYNC_END)
            except OSError:
                pass
        if first_map is not None:
            first_map.close()
        if second_map is not None:
            second_map.close()
        if first_fd >= 0 and not first_closed:
            try:
                os.close(first_fd)
            except OSError:
                pass
        if second_fd >= 0 and not second_closed:
            try:
                os.close(second_fd)
            except OSError:
                pass
        if heap_fd >= 0:
            os.close(heap_fd)


# parse_args(arguments)
# Parses one heap path, allocation size, and report path. It returns an argparse
# namespace, writes usage errors to stderr, and does not inspect the target.
def parse_args(arguments):
    parser = argparse.ArgumentParser(
        description="Exercise one Linux DMA-BUF heap through its public UAPI",
    )
    parser.add_argument("--heap", required=True)
    parser.add_argument("--size", required=True, type=int)
    parser.add_argument("--report", required=True)
    return parser.parse_args(arguments)


# main(arguments)
# Validates arguments, executes one heap transaction, writes its retained TSV,
# and returns 0 for PASS, 1 for a functional failure, or 2 when the requested
# heap device is absent or not a character device. It logs one result marker.
def main(arguments):
    args = parse_args(arguments)
    report = {
        "status": "UNKNOWN",
        "reason": "not-run",
        "heap": args.heap,
        "allocation_bytes": args.size,
        "alloc_ioctl": hex(DMA_HEAP_IOCTL_ALLOC),
        "sync_ioctl": hex(DMA_BUF_IOCTL_SYNC),
    }

    if (
        args.size <= 0
        or args.size > MAX_ALLOCATION_BYTES
        or args.size % mmap.PAGESIZE != 0
    ):
        report["status"] = "FAIL"
        report["reason"] = "size-outside-safe-page-aligned-range"
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=FAIL"
            + " reason=size-outside-safe-page-aligned-range"
            + " heap="
            + args.heap
        )
        return 1
    if not os.path.exists(args.heap):
        report["status"] = "SKIP"
        report["reason"] = "heap-device-absent"
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=SKIP reason=heap-device-absent heap="
            + args.heap
        )
        return 2
    if not stat.S_ISCHR(os.stat(args.heap).st_mode):
        report["status"] = "SKIP"
        report["reason"] = "heap-path-not-character-device"
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=SKIP"
            + " reason=heap-path-not-character-device heap="
            + args.heap
        )
        return 2

    try:
        exercise_heap(args.heap, args.size, report)
    except Exception as error:
        reason = str(error).replace("\n", " ").replace("\t", " ")
        report["status"] = "FAIL"
        report["reason"] = reason
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=FAIL heap="
            + args.heap
            + " reason="
            + reason.replace(" ", "-")
            + " report="
            + args.report
        )
        return 1

    report["status"] = "PASS"
    report["reason"] = "allocate-map-read-write-sync-free-verified"
    write_report(args.report, report)
    print(
        "DMABUF_HEAP_RESULT status=PASS heap="
        + args.heap
        + " bytes="
        + str(args.size)
        + " allocations=2 maps=2 sync_transactions=4"
        + " sha256="
        + report["pattern_sha256"]
        + " fd_before="
        + str(report["fd_count_before"])
        + " fd_after="
        + str(report["fd_count_after"])
        + " report="
        + args.report
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
