#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
"""Bounded Linux RTC ioctl validation with state restoration."""

import argparse
import calendar
import ctypes
import datetime
import errno
import fcntl
import os
import select
import signal
import sys
import time


PASS = 0
FAIL = 1
SKIP = 2
ERROR = 3
RTC_AF = 0x20


class RtcTime(ctypes.Structure):
    _fields_ = [
        ("tm_sec", ctypes.c_int),
        ("tm_min", ctypes.c_int),
        ("tm_hour", ctypes.c_int),
        ("tm_mday", ctypes.c_int),
        ("tm_mon", ctypes.c_int),
        ("tm_year", ctypes.c_int),
        ("tm_wday", ctypes.c_int),
        ("tm_yday", ctypes.c_int),
        ("tm_isdst", ctypes.c_int),
    ]


class RtcWakeAlarm(ctypes.Structure):
    _fields_ = [
        ("enabled", ctypes.c_ubyte),
        ("pending", ctypes.c_ubyte),
        ("time", RtcTime),
    ]


def _ioc(direction, ioctl_type, number, size):
    return (
        (direction << 30)
        | (ioctl_type << 8)
        | number
        | (size << 16)
    )


RTC_RD_TIME = _ioc(2, ord("p"), 0x09, ctypes.sizeof(RtcTime))
RTC_SET_TIME = _ioc(1, ord("p"), 0x0A, ctypes.sizeof(RtcTime))
RTC_WKALM_SET = _ioc(1, ord("p"), 0x0F, ctypes.sizeof(RtcWakeAlarm))
RTC_WKALM_RD = _ioc(2, ord("p"), 0x10, ctypes.sizeof(RtcWakeAlarm))

UNAVAILABLE_ERRNOS = {
    errno.EACCES,
    errno.EBUSY,
    errno.EINVAL,
    errno.ENODEV,
    errno.ENOENT,
    errno.ENOSYS,
    errno.ENOTTY,
    errno.EOPNOTSUPP,
    errno.EPERM,
}


def _interrupted(signum, frame):
    del frame
    raise InterruptedError("interrupted by signal {}".format(signum))


def ioctl_read(fd, request, structure_type):
    buffer = bytearray(ctypes.sizeof(structure_type))
    fcntl.ioctl(fd, request, buffer, True)
    return structure_type.from_buffer_copy(buffer)


def ioctl_write(fd, request, value):
    buffer = bytearray(bytes(value))
    fcntl.ioctl(fd, request, buffer, True)


def rtc_to_epoch(value):
    rtc_datetime = datetime.datetime(
        value.tm_year + 1900,
        value.tm_mon + 1,
        value.tm_mday,
        value.tm_hour,
        value.tm_min,
        value.tm_sec,
        tzinfo=datetime.timezone.utc,
    )
    return calendar.timegm(rtc_datetime.utctimetuple())


def epoch_to_rtc(epoch):
    rtc_datetime = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    value = RtcTime()
    value.tm_sec = rtc_datetime.second
    value.tm_min = rtc_datetime.minute
    value.tm_hour = rtc_datetime.hour
    value.tm_mday = rtc_datetime.day
    value.tm_mon = rtc_datetime.month - 1
    value.tm_year = rtc_datetime.year - 1900
    value.tm_wday = (rtc_datetime.weekday() + 1) % 7
    value.tm_yday = rtc_datetime.timetuple().tm_yday - 1
    value.tm_isdst = 0
    return value


def format_rtc(value):
    return "{:04d}-{:02d}-{:02d}T{:02d}:{:02d}:{:02d}Z".format(
        value.tm_year + 1900,
        value.tm_mon + 1,
        value.tm_mday,
        value.tm_hour,
        value.tm_min,
        value.tm_sec,
    )


def write_report(path, values):
    with open(path, "w", encoding="utf-8") as report:
        report.write("key\tvalue\n")
        for key, value in values:
            clean_value = str(value).replace("\t", " ").replace("\n", " ")
            report.write("{}\t{}\n".format(key, clean_value))


def read_sysfs_text(path):
    try:
        with open(path, "rb") as value_file:
            value = value_file.read()
    except OSError:
        return "unavailable"
    return value.replace(b"\x00", b" ").decode("utf-8", "replace").strip()


def rtc_runtime_evidence(device):
    rtc_name = os.path.basename(os.path.realpath(device))
    class_dir = os.path.join("/sys/class/rtc", rtc_name)
    device_dir = os.path.realpath(os.path.join(class_dir, "device"))
    driver_path = os.path.realpath(os.path.join(device_dir, "driver"))
    driver = os.path.basename(driver_path) if os.path.isdir(driver_path) else "unknown"
    of_node = os.path.realpath(os.path.join(device_dir, "of_node"))
    dt_available = os.path.isdir(of_node)

    def property_status(name):
        if not dt_available:
            return "unknown"
        return "present" if os.path.exists(os.path.join(of_node, name)) else "absent"

    nvmem_names = read_sysfs_text(os.path.join(of_node, "nvmem-cell-names"))
    nvmem_offset = "unknown"
    if dt_available:
        if property_status("nvmem-cells") == "present" and "offset" in nvmem_names.split():
            nvmem_offset = "present"
        else:
            nvmem_offset = "absent"

    return {
        "rtc_name": read_sysfs_text(os.path.join(class_dir, "name")),
        "driver": driver,
        "dt_node": of_node if dt_available else "unavailable",
        "dt_allow_set_time": property_status("allow-set-time"),
        "dt_nvmem_offset": nvmem_offset,
        "dt_uefi_rtc_info": property_status("qcom,uefi-rtc-info"),
    }


def emit_result(status, mode, reason, device):
    print(
        "RTC_RESULT status={} mode={} reason={} device={}".format(
            status,
            mode,
            reason,
            device,
        )
    )


def read_validation(fd, args):
    first = ioctl_read(fd, RTC_RD_TIME, RtcTime)
    first_epoch = rtc_to_epoch(first)
    time.sleep(args.read_delay)
    second = ioctl_read(fd, RTC_RD_TIME, RtcTime)
    second_epoch = rtc_to_epoch(second)
    delta = second_epoch - first_epoch
    values = [
        ("status", "PASS"),
        ("reason", "rtc-time-progressed"),
        ("device", args.device),
        ("first_time", format_rtc(first)),
        ("second_time", format_rtc(second)),
        ("elapsed_rtc_seconds", delta),
        ("sample_delay_seconds", args.read_delay),
    ]
    if delta < 1 or delta > args.read_delay + 3:
        values[0] = ("status", "FAIL")
        values[1] = ("reason", "rtc-time-did-not-progress-as-expected")
        return FAIL, values
    return PASS, values


def alarm_validation(fd, args):
    try:
        original = ioctl_read(fd, RTC_WKALM_RD, RtcWakeAlarm)
    except OSError as error:
        if error.errno in UNAVAILABLE_ERRNOS:
            return SKIP, [
                ("status", "SKIP"),
                ("reason", "wake-alarm-ioctl-unavailable"),
                ("errno", error.errno),
                ("error", error.strerror),
            ]
        raise

    values = [
        ("device", args.device),
        ("original_alarm_enabled", int(original.enabled)),
        ("original_alarm_pending", int(original.pending)),
        ("original_alarm_time", format_rtc(original.time)),
        ("alarm_delay_seconds", args.alarm_delay),
        ("alarm_timeout_seconds", args.alarm_timeout),
    ]
    if original.enabled or original.pending:
        return SKIP, [
            ("status", "SKIP"),
            ("reason", "existing-alarm-is-active"),
        ] + values

    current = ioctl_read(fd, RTC_RD_TIME, RtcTime)
    target_epoch = rtc_to_epoch(current) + args.alarm_delay
    programmed = RtcWakeAlarm()
    programmed.enabled = 1
    programmed.pending = 0
    programmed.time = epoch_to_rtc(target_epoch)
    alarm_changed = False
    status = FAIL
    reason = "alarm-validation-incomplete"

    try:
        try:
            ioctl_write(fd, RTC_WKALM_SET, programmed)
            alarm_changed = True
        except OSError as error:
            if error.errno in UNAVAILABLE_ERRNOS:
                values.extend(
                    [
                        ("errno", error.errno),
                        ("error", error.strerror),
                    ]
                )
                return SKIP, [
                    ("status", "SKIP"),
                    ("reason", "wake-alarm-programming-unavailable"),
                ] + values
            raise

        readback = ioctl_read(fd, RTC_WKALM_RD, RtcWakeAlarm)
        readback_epoch = rtc_to_epoch(readback.time)
        values.extend(
            [
                ("programmed_alarm_time", format_rtc(programmed.time)),
                ("readback_alarm_time", format_rtc(readback.time)),
                ("readback_alarm_enabled", int(readback.enabled)),
            ]
        )
        if not readback.enabled or abs(readback_epoch - target_epoch) > 1:
            reason = "wake-alarm-readback-mismatch"
            return status, [
                ("status", "FAIL"),
                ("reason", reason),
                ("restoration", "verified-on-successful-return"),
            ] + values

        ready, _, _ = select.select(
            [fd],
            [],
            [],
            args.alarm_delay + args.alarm_timeout,
        )
        if not ready:
            reason = "wake-alarm-expiration-timeout"
            return status, [
                ("status", "FAIL"),
                ("reason", reason),
                ("restoration", "verified-on-successful-return"),
            ] + values

        event_data = os.read(fd, ctypes.sizeof(ctypes.c_ulong))
        event_value = int.from_bytes(event_data, byteorder=sys.byteorder)
        event_flags = event_value & 0xFF
        after = ioctl_read(fd, RTC_RD_TIME, RtcTime)
        after_epoch = rtc_to_epoch(after)
        post_alarm = ioctl_read(fd, RTC_WKALM_RD, RtcWakeAlarm)
        values.extend(
            [
                ("event_value", "0x{:x}".format(event_value)),
                ("event_flags", "0x{:02x}".format(event_flags)),
                ("alarm_flag_observed", int(bool(event_flags & RTC_AF))),
                ("expiration_time", format_rtc(after)),
                ("expiration_delta_seconds", after_epoch - target_epoch),
                ("post_alarm_enabled", int(post_alarm.enabled)),
                ("post_alarm_pending", int(post_alarm.pending)),
            ]
        )
        if not event_flags & RTC_AF:
            reason = "rtc-event-did-not-contain-alarm-flag"
        elif after_epoch < target_epoch:
            reason = "alarm-event-arrived-before-programmed-time"
        elif after_epoch > target_epoch + args.alarm_timeout:
            reason = "alarm-event-arrived-after-timeout-window"
        else:
            status = PASS
            reason = "wake-alarm-program-readback-and-expiration-verified"
        return status, [
            ("status", "PASS" if status == PASS else "FAIL"),
            ("reason", reason),
            ("restoration", "verified-on-successful-return"),
        ] + values
    finally:
        if alarm_changed:
            restore_value = programmed
            restore_value.enabled = 0
            restore_value.pending = 0
            try:
                ioctl_write(fd, RTC_WKALM_SET, restore_value)
            except OSError as error:
                raise RuntimeError(
                    "failed to restore original wake-alarm state: {}".format(error)
                ) from error


def set_time_validation(fd, args):
    original = ioctl_read(fd, RTC_RD_TIME, RtcTime)
    original_epoch = rtc_to_epoch(original)
    started = time.monotonic()
    test_epoch = original_epoch + args.time_set_offset
    test_time = epoch_to_rtc(test_epoch)
    time_changed = False
    status = FAIL
    reason = "rtc-time-set-validation-incomplete"
    values = [
        ("device", args.device),
        ("original_time", format_rtc(original)),
        ("test_time", format_rtc(test_time)),
        ("time_set_offset_seconds", args.time_set_offset),
    ]

    try:
        try:
            ioctl_write(fd, RTC_SET_TIME, test_time)
            time_changed = True
        except OSError as error:
            if error.errno in UNAVAILABLE_ERRNOS:
                runtime = rtc_runtime_evidence(args.device)
                reason = "rtc-time-setting-unavailable"
                message = "RTC_SET_TIME is unavailable on the selected target"
                if error.errno == errno.ENODEV and runtime["driver"] == "rtc-pm8xxx":
                    reason = "rtc-pm8xxx-time-setting-target-support-unavailable"
                    if (
                        runtime["dt_allow_set_time"] == "absent"
                        and runtime["dt_nvmem_offset"] == "absent"
                        and runtime["dt_uefi_rtc_info"] == "absent"
                    ):
                        message = (
                            "rtc-pm8xxx returned ENODEV because the target lacks "
                            "DT allow-set-time and persistent RTC offset storage "
                            "through NVMEM or UEFI"
                        )
                    else:
                        message = (
                            "rtc-pm8xxx returned ENODEV because target RTC "
                            "time-setting support is unavailable"
                        )
                values.extend(
                    [
                        ("errno", error.errno),
                        ("error", error.strerror),
                        ("message", message),
                        ("driver", runtime["driver"]),
                        ("rtc_name", runtime["rtc_name"]),
                        ("dt_node", runtime["dt_node"]),
                        ("dt_allow_set_time", runtime["dt_allow_set_time"]),
                        ("dt_nvmem_offset", runtime["dt_nvmem_offset"]),
                        ("dt_uefi_rtc_info", runtime["dt_uefi_rtc_info"]),
                    ]
                )
                return SKIP, [
                    ("status", "SKIP"),
                    ("reason", reason),
                ] + values
            raise

        readback = ioctl_read(fd, RTC_RD_TIME, RtcTime)
        readback_epoch = rtc_to_epoch(readback)
        values.append(("set_readback_time", format_rtc(readback)))
        if abs(readback_epoch - test_epoch) > 1:
            reason = "rtc-time-set-readback-mismatch"
            return status, [
                ("status", "FAIL"),
                ("reason", reason),
                ("restoration", "verified-on-successful-return"),
            ] + values

        time.sleep(args.read_delay)
        progressed = ioctl_read(fd, RTC_RD_TIME, RtcTime)
        progressed_epoch = rtc_to_epoch(progressed)
        values.extend(
            [
                ("progressed_time", format_rtc(progressed)),
                ("progressed_seconds", progressed_epoch - readback_epoch),
            ]
        )
        if progressed_epoch <= readback_epoch:
            reason = "rtc-time-did-not-progress-after-set"
        else:
            status = PASS
            reason = "rtc-time-set-readback-and-progression-verified"
        return status, [
            ("status", "PASS" if status == PASS else "FAIL"),
            ("reason", reason),
            ("restoration", "verified-on-successful-return"),
        ] + values
    finally:
        if time_changed:
            elapsed = max(0, round(time.monotonic() - started))
            restore_time = epoch_to_rtc(original_epoch + elapsed)
            try:
                ioctl_write(fd, RTC_SET_TIME, restore_time)
                restored = ioctl_read(fd, RTC_RD_TIME, RtcTime)
                if abs(rtc_to_epoch(restored) - rtc_to_epoch(restore_time)) > 1:
                    raise RuntimeError("RTC time restoration readback mismatch")
            except (OSError, RuntimeError, ValueError) as error:
                raise RuntimeError(
                    "failed to restore original RTC timeline: {}".format(error)
                ) from error


def self_check(args):
    values = [
        ("status", "PASS"),
        ("reason", "rtc-abi-layout-validated"),
        ("rtc_time_size", ctypes.sizeof(RtcTime)),
        ("rtc_wkalrm_size", ctypes.sizeof(RtcWakeAlarm)),
        ("rtc_rd_time", "0x{:x}".format(RTC_RD_TIME)),
        ("rtc_set_time", "0x{:x}".format(RTC_SET_TIME)),
        ("rtc_wkalm_set", "0x{:x}".format(RTC_WKALM_SET)),
        ("rtc_wkalm_rd", "0x{:x}".format(RTC_WKALM_RD)),
    ]
    if ctypes.sizeof(RtcTime) != 36 or ctypes.sizeof(RtcWakeAlarm) != 40:
        values[0] = ("status", "FAIL")
        values[1] = ("reason", "unexpected-rtc-abi-layout")
        return FAIL, values
    return PASS, values


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="/dev/rtc0")
    parser.add_argument(
        "--mode",
        required=True,
        choices=("read", "alarm", "set-time", "self-check"),
    )
    parser.add_argument("--report", required=True)
    parser.add_argument("--read-delay", type=int, default=2)
    parser.add_argument("--alarm-delay", type=int, default=5)
    parser.add_argument("--alarm-timeout", type=int, default=3)
    parser.add_argument("--time-set-offset", type=int, default=3)
    args = parser.parse_args()
    for value in (
        args.read_delay,
        args.alarm_delay,
        args.alarm_timeout,
        args.time_set_offset,
    ):
        if value <= 0:
            parser.error("delay, timeout, and offset values must be positive")
    return args


def main():
    args = parse_args()
    signal.signal(signal.SIGINT, _interrupted)
    signal.signal(signal.SIGTERM, _interrupted)

    if args.mode == "self-check":
        status, values = self_check(args)
    else:
        try:
            fd = os.open(args.device, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        except OSError as error:
            status = SKIP if error.errno in UNAVAILABLE_ERRNOS else FAIL
            values = [
                ("status", "SKIP" if status == SKIP else "FAIL"),
                ("reason", "rtc-device-open-unavailable"),
                ("device", args.device),
                ("errno", error.errno),
                ("error", error.strerror),
            ]
        else:
            try:
                if args.mode == "read":
                    status, values = read_validation(fd, args)
                elif args.mode == "alarm":
                    status, values = alarm_validation(fd, args)
                else:
                    status, values = set_time_validation(fd, args)
            except (OSError, RuntimeError, ValueError, OverflowError) as error:
                status = FAIL
                values = [
                    ("status", "FAIL"),
                    ("reason", "rtc-validation-error"),
                    ("device", args.device),
                    ("error", str(error)),
                ]
            finally:
                os.close(fd)

    write_report(args.report, values)
    reason = next(value for key, value in values if key == "reason")
    status_name = next(value for key, value in values if key == "status")
    emit_result(status_name, args.mode, reason, args.device)
    return status


if __name__ == "__main__":
    sys.exit(main())
