#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Run a deterministic ONNX Runtime QNN HTP inference without CPU fallback."""

import argparse
import ctypes
import ctypes.util
import glob
import hashlib
import os
import re
import struct
import subprocess
import sys


ORT_API_VERSION = 22
ORT_LOGGING_LEVEL_WARNING = 2
ORT_ARENA_ALLOCATOR = 1
ORT_MEM_TYPE_DEFAULT = 0
ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT = 1
ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8 = 2
ORT_HARDWARE_DEVICE_TYPE_CPU = 0
ORT_HARDWARE_DEVICE_TYPE_GPU = 1
ORT_HARDWARE_DEVICE_TYPE_NPU = 2
QNN_EP_NAME = "QNNExecutionProvider"

API_INDEX = {
    "GetErrorMessage": 2,
    "CreateEnv": 3,
    "CreateSessionFromArray": 8,
    "Run": 9,
    "CreateSessionOptions": 10,
    "CreateTensorWithDataAsOrtValue": 49,
    "GetTensorMutableData": 51,
    "GetTensorElementType": 60,
    "GetDimensionsCount": 61,
    "GetDimensions": 62,
    "GetTensorTypeAndShape": 65,
    "CreateCpuMemoryInfo": 69,
    "ReleaseEnv": 92,
    "ReleaseStatus": 93,
    "ReleaseMemoryInfo": 94,
    "ReleaseSession": 95,
    "ReleaseValue": 96,
    "ReleaseTensorTypeAndShapeInfo": 99,
    "ReleaseSessionOptions": 100,
    "AddSessionConfigEntry": 130,
    "RegisterExecutionProviderLibrary": 301,
    "UnregisterExecutionProviderLibrary": 302,
    "GetEpDevices": 303,
    "SessionOptionsAppendExecutionProvider_V2": 304,
    "HardwareDevice_Type": 307,
    "HardwareDevice_VendorId": 308,
    "HardwareDevice_Vendor": 309,
    "HardwareDevice_DeviceId": 310,
    "EpDevice_EpName": 312,
    "EpDevice_Device": 316,
}


# encode_varint(value)
# Encodes one non-negative protobuf integer and returns bytes. It has no side
# effects and raises ValueError for a negative input.
def encode_varint(value):
    if value < 0:
        raise ValueError("protobuf varint input must be non-negative")
    encoded = bytearray()
    while value > 0x7F:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


# encode_field_varint(field_number, value)
# Encodes one protobuf varint field and returns bytes. Inputs are positive field
# number and non-negative integer. It has no side effects.
def encode_field_varint(field_number, value):
    return encode_varint((field_number << 3) | 0) + encode_varint(value)


# encode_field_bytes(field_number, value)
# Encodes one protobuf length-delimited field and returns bytes. VALUE must be a
# bytes-like object. It has no side effects.
def encode_field_bytes(field_number, value):
    return encode_varint((field_number << 3) | 2) + encode_varint(len(value)) + value


# encode_field_string(field_number, value)
# Encodes one UTF-8 protobuf string field and returns bytes. It has no side
# effects.
def encode_field_string(field_number, value):
    return encode_field_bytes(field_number, value.encode("utf-8"))


# encode_tensor_shape(dimensions)
# Encodes an ONNX TensorShapeProto from integer dimensions and returns bytes.
# It has no side effects.
def encode_tensor_shape(dimensions):
    encoded = bytearray()
    for dimension in dimensions:
        dimension_message = encode_field_varint(1, dimension)
        encoded.extend(encode_field_bytes(1, dimension_message))
    return bytes(encoded)


# encode_tensor_type(element_type, dimensions)
# Encodes an ONNX TypeProto tensor with the supplied element type and dimensions.
# It returns bytes and has no side effects.
def encode_tensor_type(element_type, dimensions):
    tensor_message = encode_field_varint(1, element_type)
    tensor_message += encode_field_bytes(2, encode_tensor_shape(dimensions))
    return encode_field_bytes(1, tensor_message)


# encode_value_info(name, element_type, dimensions)
# Encodes an ONNX ValueInfoProto and returns bytes. It has no side effects.
def encode_value_info(name, element_type, dimensions):
    encoded = encode_field_string(1, name)
    encoded += encode_field_bytes(2, encode_tensor_type(element_type, dimensions))
    return encoded


# encode_tensor(name, element_type, dimensions, raw_data)
# Encodes an ONNX TensorProto initializer and returns bytes. RAW_DATA is the
# exact little-endian tensor payload. It has no side effects.
def encode_tensor(name, element_type, dimensions, raw_data):
    encoded = bytearray()
    for dimension in dimensions:
        encoded.extend(encode_field_varint(1, dimension))
    encoded.extend(encode_field_varint(2, element_type))
    encoded.extend(encode_field_string(8, name))
    encoded.extend(encode_field_bytes(9, raw_data))
    return bytes(encoded)


# encode_node(name, operation, inputs, outputs)
# Encodes an ONNX NodeProto with ordered input and output names and returns
# bytes. It has no side effects.
def encode_node(name, operation, inputs, outputs):
    encoded = bytearray()
    for input_name in inputs:
        encoded.extend(encode_field_string(1, input_name))
    for output_name in outputs:
        encoded.extend(encode_field_string(2, output_name))
    encoded.extend(encode_field_string(3, name))
    encoded.extend(encode_field_string(4, operation))
    return bytes(encoded)


# build_qdq_add_model()
# Builds a static ONNX opset-13 QDQ Add graph and returns its serialized bytes,
# deterministic float input, and expected float output. It has no side effects.
def build_qdq_add_model():
    scale = struct.pack("<f", 0.125)
    zero_point = bytes([128])
    bias_quantized = bytes([132, 136, 124, 128])

    nodes = [
        encode_node(
            "input_quantize",
            "QuantizeLinear",
            ["input", "scale", "zero_point"],
            ["input_quantized"],
        ),
        encode_node(
            "input_dequantize",
            "DequantizeLinear",
            ["input_quantized", "scale", "zero_point"],
            ["input_dequantized"],
        ),
        encode_node(
            "bias_dequantize",
            "DequantizeLinear",
            ["bias_quantized", "scale", "zero_point"],
            ["bias_dequantized"],
        ),
        encode_node(
            "deterministic_add",
            "Add",
            ["input_dequantized", "bias_dequantized"],
            ["sum_float"],
        ),
        encode_node(
            "output_quantize",
            "QuantizeLinear",
            ["sum_float", "scale", "zero_point"],
            ["output_quantized"],
        ),
        encode_node(
            "output_dequantize",
            "DequantizeLinear",
            ["output_quantized", "scale", "zero_point"],
            ["output"],
        ),
    ]
    initializers = [
        encode_tensor("scale", ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, [], scale),
        encode_tensor(
            "zero_point",
            ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8,
            [],
            zero_point,
        ),
        encode_tensor(
            "bias_quantized",
            ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8,
            [1, 4],
            bias_quantized,
        ),
    ]

    graph = bytearray()
    for node in nodes:
        graph.extend(encode_field_bytes(1, node))
    graph.extend(encode_field_string(2, "qnn_qdq_add"))
    for initializer in initializers:
        graph.extend(encode_field_bytes(5, initializer))
    graph.extend(
        encode_field_bytes(
            11,
            encode_value_info(
                "input",
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                [1, 4],
            ),
        )
    )
    graph.extend(
        encode_field_bytes(
            12,
            encode_value_info(
                "output",
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                [1, 4],
            ),
        )
    )

    opset = encode_field_varint(2, 13)
    model = encode_field_varint(1, 9)
    model += encode_field_string(2, "qcom-linux-testkit")
    model += encode_field_varint(5, 1)
    model += encode_field_bytes(7, bytes(graph))
    model += encode_field_bytes(8, opset)

    return (
        model,
        [-1.0, 0.0, 1.0, 2.0],
        [-0.5, 1.0, 0.5, 2.0],
    )


# library_search_roots()
# Returns a deduplicated list of standard and loader-provided Linux library
# directories. It has no side effects.
def library_search_roots():
    roots = []
    for path in os.environ.get("LD_LIBRARY_PATH", "").split(os.pathsep):
        if path:
            roots.append(path)
    roots.extend(
        [
            "/usr/lib",
            "/usr/lib64",
            "/usr/local/lib",
            "/lib",
            "/lib64",
            "/usr/lib/aarch64-linux-gnu",
            "/lib/aarch64-linux-gnu",
        ]
    )
    deduplicated = []
    for path in roots:
        normalized = os.path.realpath(path)
        if normalized not in deduplicated:
            deduplicated.append(normalized)
    return deduplicated


# ldconfig_candidates(soname_prefix)
# Returns matching absolute paths from a bounded ldconfig cache query. Command
# failures and timeouts produce an empty list and no persistent side effects.
def ldconfig_candidates(soname_prefix):
    try:
        result = subprocess.run(
            ["ldconfig", "-p"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
            check=False,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []
    candidates = []
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped.startswith(soname_prefix):
            continue
        marker = " => "
        if marker not in stripped:
            continue
        candidate = stripped.split(marker, 1)[1].strip()
        if os.path.isfile(candidate):
            candidates.append(os.path.realpath(candidate))
    return candidates


# library_candidate_key(path, soname_prefix)
# Returns an ordering key that prefers an exact unversioned SONAME and otherwise
# compares numeric version components. It has no side effects.
def library_candidate_key(path, soname_prefix):
    basename = os.path.basename(path)
    exact_name = 1 if basename == soname_prefix else 0
    suffix = basename[len(soname_prefix) :]
    version = tuple(int(value) for value in re.findall(r"[0-9]+", suffix))
    return exact_name, version, path


# discover_library(override, stem)
# Resolves an explicit library path or dynamically searches the loader cache and
# standard directories. It returns (path, source), or (None, reason). It does
# not load the library or mutate target state.
def discover_library(override, stem):
    if override:
        if os.path.isfile(override):
            return os.path.realpath(override), "override"
        if os.path.sep not in override:
            return override, "override-loader-name"
        return None, "invalid-override"

    loader_name = ctypes.util.find_library(stem)
    if loader_name:
        return loader_name, "ctypes-loader-cache"

    prefix = "lib" + stem + ".so"
    candidates = ldconfig_candidates(prefix)
    if candidates:
        return max(
            candidates,
            key=lambda path: library_candidate_key(path, prefix),
        ), "ldconfig"

    candidates = []
    for root in library_search_roots():
        candidates.extend(glob.glob(os.path.join(root, prefix + "*")))
        for child in glob.glob(os.path.join(root, "*")):
            if os.path.isdir(child):
                candidates.extend(glob.glob(os.path.join(child, prefix + "*")))
    files = sorted(
        {
            os.path.realpath(candidate)
            for candidate in candidates
            if os.path.isfile(candidate)
        }
    )
    if files:
        return max(
            files,
            key=lambda path: library_candidate_key(path, prefix),
        ), "standard-directory"
    return None, "not-found"


# bind_api_function(api_table, name, result_type, argument_types)
# Returns a ctypes callable for a named ORT API v22 table entry. It has no side
# effects and raises RuntimeError when the table entry is unavailable.
def bind_api_function(api_table, name, result_type, argument_types):
    address = api_table[API_INDEX[name]]
    if not address:
        raise RuntimeError("ORT API entry is unavailable: " + name)
    prototype = ctypes.CFUNCTYPE(result_type, *argument_types)
    return prototype(address)


# check_status(status, operation, get_error_message, release_status)
# Raises RuntimeError with the ORT diagnostic when STATUS is non-null. A non-null
# status is released before returning or raising. It emits no stdout.
def check_status(status, operation, get_error_message, release_status):
    if not status:
        return
    message_pointer = get_error_message(status)
    message = (
        message_pointer.decode("utf-8", errors="replace")
        if message_pointer
        else "unknown ONNX Runtime error"
    )
    release_status(status)
    raise RuntimeError(operation + ": " + message)


# format_values(values)
# Returns a stable comma-separated decimal representation of numeric values. It
# has no side effects.
def format_values(values):
    return ",".join(format(value, ".6f") for value in values)


# hardware_type_name(device_type)
# Returns the stable CPU, GPU, NPU, or unknown label for an ORT hardware-device
# enum value. It has no side effects.
def hardware_type_name(device_type):
    names = {
        ORT_HARDWARE_DEVICE_TYPE_CPU: "cpu",
        ORT_HARDWARE_DEVICE_TYPE_GPU: "gpu",
        ORT_HARDWARE_DEVICE_TYPE_NPU: "npu",
    }
    return names.get(device_type, "unknown-" + str(device_type))


# write_report(path, report)
# Replaces PATH with a two-column TSV report from the supplied mapping. It
# returns no value and creates parent directories when required.
def write_report(path, report):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as report_file:
        report_file.write("key\tvalue\n")
        for key, value in report.items():
            report_file.write(str(key) + "\t" + str(value) + "\n")


# run_inference(ort_library, qnn_plugin, model_path, report)
# Loads ORT and the QNN plugin, selects QNN NPU devices, disables CPU fallback,
# runs the deterministic QDQ Add model on HTP, and validates shape, type, and
# output values. It updates REPORT, writes MODEL_PATH, and raises on any failure.
def run_inference(ort_library, qnn_plugin, model_path, report):
    runtime = ctypes.CDLL(ort_library, mode=getattr(ctypes, "RTLD_GLOBAL", 0))
    runtime.OrtGetApiBase.argtypes = []
    runtime.OrtGetApiBase.restype = ctypes.c_void_p
    api_base_address = runtime.OrtGetApiBase()
    if not api_base_address:
        raise RuntimeError("OrtGetApiBase returned a null pointer")

    api_base_table = ctypes.cast(
        api_base_address,
        ctypes.POINTER(ctypes.c_void_p),
    )
    get_api = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_uint32)(api_base_table[0])
    get_version_string = ctypes.CFUNCTYPE(ctypes.c_char_p)(api_base_table[1])
    version_pointer = get_version_string()
    runtime_version = (
        version_pointer.decode("utf-8", errors="replace")
        if version_pointer
        else "unknown"
    )
    report["ort_version"] = runtime_version
    print(
        "QNN_RUNTIME status=loaded"
        + " ort_library="
        + ort_library
        + " ort_version="
        + runtime_version
    )

    api_address = get_api(ORT_API_VERSION)
    if not api_address:
        raise RuntimeError(
            "ONNX Runtime does not expose required C API version "
            + str(ORT_API_VERSION)
        )
    api_table = ctypes.cast(api_address, ctypes.POINTER(ctypes.c_void_p))

    get_error_message = bind_api_function(
        api_table,
        "GetErrorMessage",
        ctypes.c_char_p,
        [ctypes.c_void_p],
    )
    release_status = bind_api_function(
        api_table,
        "ReleaseStatus",
        None,
        [ctypes.c_void_p],
    )
    create_env = bind_api_function(
        api_table,
        "CreateEnv",
        ctypes.c_void_p,
        [ctypes.c_int, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)],
    )
    create_session_options = bind_api_function(
        api_table,
        "CreateSessionOptions",
        ctypes.c_void_p,
        [ctypes.POINTER(ctypes.c_void_p)],
    )
    path_argument_type = ctypes.c_wchar_p if os.name == "nt" else ctypes.c_char_p
    register_ep_library = bind_api_function(
        api_table,
        "RegisterExecutionProviderLibrary",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.c_char_p, path_argument_type],
    )
    unregister_ep_library = bind_api_function(
        api_table,
        "UnregisterExecutionProviderLibrary",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.c_char_p],
    )
    get_ep_devices = bind_api_function(
        api_table,
        "GetEpDevices",
        ctypes.c_void_p,
        [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p)),
            ctypes.POINTER(ctypes.c_size_t),
        ],
    )
    ep_device_name = bind_api_function(
        api_table,
        "EpDevice_EpName",
        ctypes.c_char_p,
        [ctypes.c_void_p],
    )
    ep_device_hardware = bind_api_function(
        api_table,
        "EpDevice_Device",
        ctypes.c_void_p,
        [ctypes.c_void_p],
    )
    hardware_device_type = bind_api_function(
        api_table,
        "HardwareDevice_Type",
        ctypes.c_int,
        [ctypes.c_void_p],
    )
    hardware_device_vendor_id = bind_api_function(
        api_table,
        "HardwareDevice_VendorId",
        ctypes.c_uint32,
        [ctypes.c_void_p],
    )
    hardware_device_vendor = bind_api_function(
        api_table,
        "HardwareDevice_Vendor",
        ctypes.c_char_p,
        [ctypes.c_void_p],
    )
    hardware_device_id = bind_api_function(
        api_table,
        "HardwareDevice_DeviceId",
        ctypes.c_uint32,
        [ctypes.c_void_p],
    )
    append_ep = bind_api_function(
        api_table,
        "SessionOptionsAppendExecutionProvider_V2",
        ctypes.c_void_p,
        [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_size_t,
            ctypes.POINTER(ctypes.c_char_p),
            ctypes.POINTER(ctypes.c_char_p),
            ctypes.c_size_t,
        ],
    )
    add_session_config = bind_api_function(
        api_table,
        "AddSessionConfigEntry",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p],
    )
    create_session = bind_api_function(
        api_table,
        "CreateSessionFromArray",
        ctypes.c_void_p,
        [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
        ],
    )
    create_cpu_memory_info = bind_api_function(
        api_table,
        "CreateCpuMemoryInfo",
        ctypes.c_void_p,
        [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)],
    )
    create_tensor = bind_api_function(
        api_table,
        "CreateTensorWithDataAsOrtValue",
        ctypes.c_void_p,
        [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.POINTER(ctypes.c_int64),
            ctypes.c_size_t,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_void_p),
        ],
    )
    run_session = bind_api_function(
        api_table,
        "Run",
        ctypes.c_void_p,
        [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_char_p),
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_size_t,
            ctypes.POINTER(ctypes.c_char_p),
            ctypes.c_size_t,
            ctypes.POINTER(ctypes.c_void_p),
        ],
    )
    get_tensor_type_shape = bind_api_function(
        api_table,
        "GetTensorTypeAndShape",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)],
    )
    get_tensor_element_type = bind_api_function(
        api_table,
        "GetTensorElementType",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)],
    )
    get_dimensions_count = bind_api_function(
        api_table,
        "GetDimensionsCount",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)],
    )
    get_dimensions = bind_api_function(
        api_table,
        "GetDimensions",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int64), ctypes.c_size_t],
    )
    get_tensor_data = bind_api_function(
        api_table,
        "GetTensorMutableData",
        ctypes.c_void_p,
        [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)],
    )
    release_env = bind_api_function(api_table, "ReleaseEnv", None, [ctypes.c_void_p])
    release_memory_info = bind_api_function(
        api_table,
        "ReleaseMemoryInfo",
        None,
        [ctypes.c_void_p],
    )
    release_session = bind_api_function(
        api_table,
        "ReleaseSession",
        None,
        [ctypes.c_void_p],
    )
    release_value = bind_api_function(api_table, "ReleaseValue", None, [ctypes.c_void_p])
    release_shape_info = bind_api_function(
        api_table,
        "ReleaseTensorTypeAndShapeInfo",
        None,
        [ctypes.c_void_p],
    )
    release_session_options = bind_api_function(
        api_table,
        "ReleaseSessionOptions",
        None,
        [ctypes.c_void_p],
    )

    environment = ctypes.c_void_p()
    session_options = ctypes.c_void_p()
    session = ctypes.c_void_p()
    memory_info = ctypes.c_void_p()
    input_value = ctypes.c_void_p()
    output_value = ctypes.c_void_p()
    shape_info = ctypes.c_void_p()
    ep_registered = False
    primary_error = None
    cleanup_errors = []

    try:
        check_status(
            create_env(
                ORT_LOGGING_LEVEL_WARNING,
                b"qcom-linux-testkit-qnn",
                ctypes.byref(environment),
            ),
            "CreateEnv",
            get_error_message,
            release_status,
        )
        check_status(
            register_ep_library(
                environment,
                QNN_EP_NAME.encode("ascii"),
                qnn_plugin if os.name == "nt" else os.fsencode(qnn_plugin),
            ),
            "RegisterExecutionProviderLibrary",
            get_error_message,
            release_status,
        )
        ep_registered = True
        print(
            "QNN_PLUGIN status=registered"
            + " registration="
            + QNN_EP_NAME
            + " path="
            + qnn_plugin
        )

        ep_devices_pointer = ctypes.POINTER(ctypes.c_void_p)()
        ep_device_count = ctypes.c_size_t()
        check_status(
            get_ep_devices(
                environment,
                ctypes.byref(ep_devices_pointer),
                ctypes.byref(ep_device_count),
            ),
            "GetEpDevices",
            get_error_message,
            release_status,
        )
        selected_devices = []
        discovered_devices = []
        for device_index in range(ep_device_count.value):
            device = ep_devices_pointer[device_index]
            name_pointer = ep_device_name(device)
            name = (
                name_pointer.decode("utf-8", errors="replace")
                if name_pointer
                else "unknown"
            )
            hardware_device = ep_device_hardware(device)
            if hardware_device:
                device_type = hardware_device_type(hardware_device)
                vendor_id = hardware_device_vendor_id(hardware_device)
                vendor_pointer = hardware_device_vendor(hardware_device)
                vendor = (
                    vendor_pointer.decode("utf-8", errors="replace")
                    if vendor_pointer
                    else "unknown"
                )
                device_id = hardware_device_id(hardware_device)
            else:
                device_type = -1
                vendor_id = 0
                vendor = "unknown"
                device_id = 0
            device_type_label = hardware_type_name(device_type)
            selected = name == QNN_EP_NAME and device_type == ORT_HARDWARE_DEVICE_TYPE_NPU
            discovered_devices.append(
                name
                + ":"
                + device_type_label
                + ":"
                + str(vendor_id)
                + ":"
                + str(device_id)
            )
            print(
                "QNN_EP_DEVICE index="
                + str(device_index)
                + " name="
                + name
                + " type="
                + device_type_label
                + " vendor="
                + vendor.replace(" ", "-")
                + " vendor_id="
                + str(vendor_id)
                + " device_id="
                + str(device_id)
                + " selected="
                + ("yes" if selected else "no")
            )
            if selected:
                selected_devices.append(device)
        report["ep_devices"] = ",".join(discovered_devices) or "none"
        report["selected_device_count"] = len(selected_devices)
        if not selected_devices:
            raise RuntimeError(
                "registered QNN plugin exposed no NPU hardware device"
            )

        check_status(
            create_session_options(ctypes.byref(session_options)),
            "CreateSessionOptions",
            get_error_message,
            release_status,
        )
        check_status(
            add_session_config(
                session_options,
                b"session.disable_cpu_ep_fallback",
                b"1",
            ),
            "AddSessionConfigEntry(session.disable_cpu_ep_fallback)",
            get_error_message,
            release_status,
        )

        device_array = (ctypes.c_void_p * len(selected_devices))(*selected_devices)
        option_keys = (ctypes.c_char_p * 2)(
            b"backend_type",
            b"offload_graph_io_quantization",
        )
        option_values = (ctypes.c_char_p * 2)(b"htp", b"0")
        check_status(
            append_ep(
                session_options,
                environment,
                device_array,
                len(selected_devices),
                option_keys,
                option_values,
                2,
            ),
            "SessionOptionsAppendExecutionProvider_V2",
            get_error_message,
            release_status,
        )
        print(
            "QNN_POLICY provider="
            + QNN_EP_NAME
            + " backend=htp cpu_fallback=disabled"
            + " offload_graph_io_quantization=0"
        )

        model_bytes, input_values, expected_values = build_qdq_add_model()
        with open(model_path, "wb") as model_file:
            model_file.write(model_bytes)
        model_digest = hashlib.sha256(model_bytes).hexdigest()
        report["model_sha256"] = model_digest
        report["model_bytes"] = len(model_bytes)
        report["input"] = format_values(input_values)
        report["expected"] = format_values(expected_values)
        print(
            "QNN_MODEL name=qdq-add-opset13"
            + " bytes="
            + str(len(model_bytes))
            + " sha256="
            + model_digest
            + " artifact="
            + model_path
        )
        print(
            "QNN_INPUT shape=1x4 values="
            + format_values(input_values)
            + " expected="
            + format_values(expected_values)
        )

        model_buffer = ctypes.create_string_buffer(model_bytes)
        check_status(
            create_session(
                environment,
                ctypes.cast(model_buffer, ctypes.c_void_p),
                len(model_bytes),
                session_options,
                ctypes.byref(session),
            ),
            "CreateSessionFromArray with CPU fallback disabled",
            get_error_message,
            release_status,
        )

        check_status(
            create_cpu_memory_info(
                ORT_ARENA_ALLOCATOR,
                ORT_MEM_TYPE_DEFAULT,
                ctypes.byref(memory_info),
            ),
            "CreateCpuMemoryInfo",
            get_error_message,
            release_status,
        )
        input_buffer = (ctypes.c_float * len(input_values))(*input_values)
        input_shape = (ctypes.c_int64 * 2)(1, len(input_values))
        check_status(
            create_tensor(
                memory_info,
                ctypes.cast(input_buffer, ctypes.c_void_p),
                ctypes.sizeof(input_buffer),
                input_shape,
                2,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                ctypes.byref(input_value),
            ),
            "CreateTensorWithDataAsOrtValue",
            get_error_message,
            release_status,
        )

        input_names = (ctypes.c_char_p * 1)(b"input")
        input_tensors = (ctypes.c_void_p * 1)(input_value.value)
        output_names = (ctypes.c_char_p * 1)(b"output")
        output_tensors = (ctypes.c_void_p * 1)()
        check_status(
            run_session(
                session,
                None,
                input_names,
                input_tensors,
                1,
                output_names,
                1,
                output_tensors,
            ),
            "Run",
            get_error_message,
            release_status,
        )
        output_value = ctypes.c_void_p(output_tensors[0])
        if not output_value.value:
            raise RuntimeError("Run returned a null output tensor")

        check_status(
            get_tensor_type_shape(output_value, ctypes.byref(shape_info)),
            "GetTensorTypeAndShape",
            get_error_message,
            release_status,
        )
        element_type = ctypes.c_int()
        check_status(
            get_tensor_element_type(shape_info, ctypes.byref(element_type)),
            "GetTensorElementType",
            get_error_message,
            release_status,
        )
        if element_type.value != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
            raise RuntimeError(
                "output tensor element type is "
                + str(element_type.value)
                + ", expected float"
            )
        dimension_count = ctypes.c_size_t()
        check_status(
            get_dimensions_count(shape_info, ctypes.byref(dimension_count)),
            "GetDimensionsCount",
            get_error_message,
            release_status,
        )
        dimensions = (ctypes.c_int64 * dimension_count.value)()
        check_status(
            get_dimensions(shape_info, dimensions, dimension_count.value),
            "GetDimensions",
            get_error_message,
            release_status,
        )
        observed_shape = [dimensions[index] for index in range(dimension_count.value)]
        if observed_shape != [1, 4]:
            raise RuntimeError(
                "output tensor shape is "
                + "x".join(str(value) for value in observed_shape)
                + ", expected 1x4"
            )

        output_data_pointer = ctypes.c_void_p()
        check_status(
            get_tensor_data(output_value, ctypes.byref(output_data_pointer)),
            "GetTensorMutableData",
            get_error_message,
            release_status,
        )
        output_array = ctypes.cast(
            output_data_pointer,
            ctypes.POINTER(ctypes.c_float * len(expected_values)),
        ).contents
        observed_values = [float(value) for value in output_array]
        errors = [
            abs(observed - expected)
            for observed, expected in zip(observed_values, expected_values)
        ]
        max_abs_error = max(errors)
        tolerance = 0.000001
        report["observed"] = format_values(observed_values)
        report["max_abs_error"] = format(max_abs_error, ".9f")
        report["tolerance"] = format(tolerance, ".9f")
        if max_abs_error > tolerance:
            raise RuntimeError(
                "deterministic output mismatch, observed="
                + format_values(observed_values)
                + " expected="
                + format_values(expected_values)
                + " max_abs_error="
                + format(max_abs_error, ".9f")
            )
        print(
            "QNN_OUTPUT shape=1x4"
            + " observed="
            + format_values(observed_values)
            + " expected="
            + format_values(expected_values)
            + " max_abs_error="
            + format(max_abs_error, ".9f")
            + " tolerance="
            + format(tolerance, ".9f")
        )
    except Exception as error:
        primary_error = error
    finally:
        if shape_info.value:
            release_shape_info(shape_info)
        if output_value.value:
            release_value(output_value)
        if input_value.value:
            release_value(input_value)
        if memory_info.value:
            release_memory_info(memory_info)
        if session.value:
            release_session(session)
        if session_options.value:
            release_session_options(session_options)
        if ep_registered and environment.value:
            unregister_status = unregister_ep_library(
                environment,
                QNN_EP_NAME.encode("ascii"),
            )
            if unregister_status:
                message_pointer = get_error_message(unregister_status)
                message = (
                    message_pointer.decode("utf-8", errors="replace")
                    if message_pointer
                    else "unknown ONNX Runtime error"
                )
                release_status(unregister_status)
                cleanup_errors.append("UnregisterExecutionProviderLibrary: " + message)
        if environment.value:
            release_env(environment)

    if primary_error is not None:
        raise primary_error
    if cleanup_errors:
        raise RuntimeError("; ".join(cleanup_errors))


# parse_args(arguments)
# Parses command-line paths into an argparse namespace. It writes usage errors
# to stderr, returns the parsed namespace, and does not probe the runtime.
def parse_args(arguments):
    parser = argparse.ArgumentParser(
        description="Run deterministic ONNX Runtime QNN HTP inference",
    )
    parser.add_argument("--ort-library", default="")
    parser.add_argument("--qnn-plugin", default="")
    parser.add_argument("--model-file", required=True)
    parser.add_argument("--report-file", required=True)
    return parser.parse_args(arguments)


# main(arguments)
# Discovers runtime libraries, executes the QNN HTP validation, writes the TSV
# report, and returns 0 for PASS, 1 for failure, or 2 when optional runtime
# components are absent. It logs machine-readable evidence to stdout.
def main(arguments):
    args = parse_args(arguments)
    report = {
        "status": "UNKNOWN",
        "reason": "not-run",
        "provider": QNN_EP_NAME,
        "backend": "htp",
        "cpu_fallback": "disabled",
        "offload_graph_io_quantization": "0",
        "ort_api_version": ORT_API_VERSION,
    }

    ort_library, ort_source = discover_library(args.ort_library, "onnxruntime")
    qnn_plugin, qnn_source = discover_library(
        args.qnn_plugin,
        "onnxruntime_providers_qnn",
    )
    report["ort_library"] = ort_library or "not-found"
    report["ort_library_source"] = ort_source
    report["qnn_plugin"] = qnn_plugin or "not-found"
    report["qnn_plugin_source"] = qnn_source
    print(
        "QNN_DISCOVERY ort_library="
        + (ort_library or "not-found")
        + " ort_source="
        + ort_source
        + " qnn_plugin="
        + (qnn_plugin or "not-found")
        + " qnn_source="
        + qnn_source
    )

    invalid_override = ort_source == "invalid-override" or qnn_source == "invalid-override"
    if invalid_override:
        report["status"] = "FAIL"
        report["reason"] = "invalid-library-override"
        write_report(args.report_file, report)
        print(
            "QNN_INFERENCE status=FAIL reason=invalid-library-override"
            + " report="
            + args.report_file
        )
        return 1
    if not ort_library or not qnn_plugin:
        report["status"] = "SKIP"
        report["reason"] = "runtime-components-not-installed"
        write_report(args.report_file, report)
        print(
            "QNN_INFERENCE status=SKIP reason=runtime-components-not-installed"
            + " report="
            + args.report_file
        )
        return 2

    try:
        run_inference(
            ort_library,
            qnn_plugin,
            args.model_file,
            report,
        )
    except Exception as error:
        report["status"] = "FAIL"
        report["reason"] = str(error).replace("\n", " ")
        write_report(args.report_file, report)
        print(
            "QNN_INFERENCE status=FAIL reason="
            + str(error).replace("\n", " ")
            + " report="
            + args.report_file
        )
        return 1

    report["status"] = "PASS"
    report["reason"] = "deterministic-output-verified"
    write_report(args.report_file, report)
    print(
        "QNN_INFERENCE status=PASS provider="
        + QNN_EP_NAME
        + " backend=htp cpu_fallback=disabled"
        + " result=deterministic-output-verified"
        + " report="
        + args.report_file
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
