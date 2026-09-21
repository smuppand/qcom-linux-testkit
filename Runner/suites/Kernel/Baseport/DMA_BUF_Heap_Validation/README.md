# DMA-BUF heap validation

`DMA_BUF_Heap_Validation` performs a bounded functional transaction through the
public Linux DMA-HEAP and DMA-BUF UAPI. It does not stop services, change device
permissions, install packages, or require a compiler on the target.

For every selected heap, the dependency-free Python client:

1. Opens the heap and allocates a page-aligned DMA-BUF.
2. Maps it shared for CPU read/write access.
3. Brackets CPU access with `DMA_BUF_IOCTL_SYNC`.
4. Verifies a new allocation is zero initialized.
5. Writes and reads back a deterministic byte pattern with an exact SHA-256
   comparison.
6. Unmaps and closes the DMA-BUF, verifies the descriptor is invalid, allocates
   a second zeroed buffer, and checks that the process descriptor count returns
   to its baseline.

This validates allocation, mapping, read/write integrity, synchronization, and
release rather than treating `/dev/dma_heap` presence as functional success.

## Heap selection

The default `auto` policy inventories every `/dev/dma_heap/*` node and selects
standard CPU-mappable heap names when they are readable and writable:
`system`, `system-uncached`, `qcom,system`, `linux,cma`, `cma`, and
`default_cma_region`. Other discovered heaps remain visible in stdout and the
retained inventory but are not mapped automatically because protected or secure
heaps can intentionally reject CPU access.

Use `all` only when the product contract says every exposed heap is CPU
mappable. Use a space-separated explicit list when a platform specification or
fixture identifies additional safe heaps. The live system can discover heap
nodes but cannot infer whether a vendor-specific heap permits CPU mapping.

```sh
./run.sh
./run.sh --heaps all
./run.sh --heaps "system linux,cma"
./run.sh --size 131072 --timeout 20
```

| Option | Environment | Default | Purpose |
|---|---|---:|---|
| `--heaps` | `DMABUF_HEAPS` | `auto` | Automatic, all, or explicit heap names |
| `--size` | `DMABUF_ALLOCATION_BYTES` | `65536` | Page-aligned bytes, at most 16777216 |
| `--timeout` | `DMABUF_TIMEOUT` | `15` | Per-heap watchdog, at most 300 seconds |

The image must provide Python 3. Missing Python produces a clean SKIP and no
package installation is attempted. An explicit heap name that is malformed,
absent, or not a character device is a FAIL. In automatic mode, absence of the
DMA-HEAP subsystem or a known safe CPU-mappable heap is a SKIP unless the
running kernel explicitly enables the system heap but fails to expose it.

## Results and artifacts

- `PASS`: every selected heap completes two allocations, mapping, zero checks,
  four synchronization transactions, exact pattern readback, and verified fd
  release without relevant kernel errors.
- `FAIL`: a declared system heap is absent, explicit selection is invalid, any
  selected functional transaction fails, data differs, descriptors leak, or
  relevant kernel errors are found.
- `SKIP`: DMA heaps are not applicable, no standard safe heap is discoverable,
  or Python 3 or kernel-log access is unavailable.

Look for `[DMABUF-POLICY]`, `[DMABUF-DISCOVERY]`, `[DMABUF-HEAP]`,
`[DMABUF-SELECTION]`, `[DMABUF-FUNCTIONAL]`, and `[DMABUF-REPORT]`. The evidence
directory retains the complete heap inventory, selected names, per-heap client
logs and reports, and the shared kernel-log snapshot.

The implementation follows the public Linux definitions in
`include/uapi/linux/dma-heap.h`, `include/uapi/linux/dma-buf.h`, and the
`tools/testing/selftests/dmabuf-heaps/dmabuf-heap.c` transaction pattern.
