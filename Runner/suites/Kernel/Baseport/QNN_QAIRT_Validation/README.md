# QNN/QAIRT Validation

This suite proves a complete ONNX Runtime inference through the Qualcomm QNN
execution-provider plugin and the QAIRT HTP backend. It does not treat library
presence, provider registration, or session creation alone as functional proof.

The test uses the public plugin execution-provider flow from ONNX Runtime 1.22
or newer:

1. Discover and load `libonnxruntime.so`.
2. Register `libonnxruntime_providers_qnn.so` as `QNNExecutionProvider`.
3. Select the runtime `OrtEpDevice` reported for that provider whose hardware
   type is NPU. CPU and GPU devices exposed by the same plugin are logged but
   rejected.
4. Configure `backend_type=htp` and
   `offload_graph_io_quantization=0`.
5. Set `session.disable_cpu_ep_fallback=1` before session creation.
6. Build and retain a deterministic ONNX opset-13 QDQ Add model.
7. Run inference and compare the complete `1x4` float output against the exact
   expected values with a `0.000001` maximum absolute-error tolerance.

The QDQ graph keeps graph input quantization and output dequantization on QNN.
Session creation fails when any graph node cannot be assigned because CPU EP
fallback is disabled. A passing run therefore proves the graph executed through
the QNN provider configured for HTP, rather than silently succeeding on the ORT
CPU provider.

## Requirements and portability

- The target image must provide ONNX Runtime with C API version 22 or newer,
  `libonnxruntime_providers_qnn.so`, the QAIRT HTP runtime dependencies, and
  Python 3.
- The runner uses only the Python standard library and calls the ORT C API with
  `ctypes`. It does not require the Python `onnx`, `onnxruntime`, or `numpy`
  packages.
- The suite does not install packages and does not require Ethernet, Wi-Fi, or
  access to an external site.
- Missing image-provided ORT, QNN plugin, or Python assets produce SKIP. An
  explicit invalid library override, a load or registration failure, no QNN EP
  device, HTP setup failure, unsupported graph, inference failure, timeout, or
  output mismatch produces FAIL.

Library selection follows `CLI > environment > dynamic discovery`. Dynamic
discovery checks the loader cache, `LD_LIBRARY_PATH`, and standard Linux library
locations. Ordinary users should leave both paths empty. Use an override only
when an image or product contract installs a library outside those locations.

## Usage

```sh
./run.sh
./run.sh --timeout 90
./run.sh \
    --ort-library /usr/lib/libonnxruntime.so.1.26.0 \
    --qnn-plugin /usr/lib/libonnxruntime_providers_qnn.so
```

Environment equivalents are `QNN_TIMEOUT`, `QNN_ORT_LIBRARY`, and
`QNN_PLUGIN_LIBRARY`.

## Result policy

- PASS: the QNN plugin registers, a `QNNExecutionProvider` device is selected,
  the HTP session is created with CPU fallback disabled, the model runs, all
  output values match, and the captured kernel log has no relevant persistent
  errors.
- FAIL: an explicitly selected asset is invalid, any installed runtime stage
  fails, the watchdog expires, output metadata or values differ, or relevant
  kernel errors are captured.
- SKIP: Python 3, ONNX Runtime, or the QNN plugin is not installed, or kernel-log
  access is unavailable for the independent health subcheck.

## Live log and retained evidence

The live log includes:

- `[QNN-POLICY]` for provider, backend, fallback, timeout, and path provenance.
- `[QNN-DISCOVERY]` for the selected Python client and architecture.
- `[QNN-INFERENCE] QNN_DISCOVERY` for resolved runtime libraries.
- `[QNN-INFERENCE] QNN_EP_DEVICE` for every execution-provider device, including
  hardware type, vendor, numeric IDs, and the NPU selection decision.
- `[QNN-INFERENCE] QNN_MODEL`, `QNN_INPUT`, and `QNN_OUTPUT` for model digest,
  input, expected values, observed values, and comparison tolerance.
- `[QNN-INFERENCE] QNN_INFERENCE status=...` for the functional result.

Each run retains:

- `qnn_inference.log`: complete runner stdout and stderr.
- `qnn_inference.tsv`: machine-readable runtime, policy, and result summary.
- `qnn_qdq_add.onnx`: the exact generated model when runtime execution begins.
- `kernel/dmesg_snapshot.log`, `kernel/dmesg_errors.log`, and
  `kernel/dmesg_access.log`: evidence from the shared kernel-log scanner.

The inference log and report are replayed to stdout up to 40 lines. Their full
paths are always printed for post-run analysis.
