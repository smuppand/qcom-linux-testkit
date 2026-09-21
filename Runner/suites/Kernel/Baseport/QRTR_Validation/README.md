# QRTR validation

`QRTR_Validation` performs a bounded, read-only QRTR control lookup and checks
the live Qualcomm IPC Router topology without assuming a board-specific service
list.

## Automatic discovery and target variation

The normal launch is simply:

```sh
./run.sh
```

This dynamically retrieves every service currently advertised by the target.
It validates the returned nodes, ports, service tuples, and topology structure.
Users do not need to provide `--expect-services` for this default validation.

The service set is not common across all SoCs. It varies with the SoC, enabled
remote processors, firmware build, device-tree configuration, and running
userspace services. The live topology can show what is present, but it cannot
by itself identify a service that should have been present and failed to start.
There is no single portable list that the generic suite can safely require on
every target.

Focused suites add capability-derived requirements where a public contract is
known. For example, `PD_Mapper_Validation` requires `64:1:1` when the PD Mapper
service applies, and `TQFTP_Validation` requires `4096:1:0` when TQFTP applies.

The suite requires QRTR runtime evidence. It prefers an image-provided
`qrtr-lookup`; when that command is absent, it uses the bundled Python client
to perform the same public AF_QIPCRTR control-port lookup. If neither provider
is runnable, the suite skips cleanly without installing packages.
It validates the table header, numeric endpoint fields, nonzero node and port
identifiers, unique endpoint tuples, and at least one advertised service.
Service `0` remains valid because QRTR can advertise the QMI control service.
The public diagnostic service `4097` uses `N/A` for its version and retains its
packed instance value, matching upstream `qrtr-lookup` output.
Raw output, normalized TSV data, counts, expected-service results, and
the kernel-log snapshot are retained under `results/QRTR_Validation/run-*/`.

## Run

```sh
./run.sh
./run.sh --timeout 15
```

CLI options override the matching environment variables:

| Option | Environment | Default | Purpose |
|---|---|---:|---|
| `--timeout` | `QRTR_TIMEOUT` | `10` | Maximum seconds for the QRTR lookup |
| `--expect-services` | `QRTR_EXPECT_SERVICES` | empty | Optional target/job-specific service requirements |

### When to use `--expect-services`

Use this option only when a board test plan, product requirement, or image
contract explicitly states that particular services must be advertised. Values
are decimal numeric selectors in these forms:

- `64` requires service 64 with any version and instance.
- `64:1` requires service 64, version 1, with any instance.
- `64:1:1` requires that exact service, version, and instance tuple.
- Multiple requirements are comma-separated, for example
  `64:1:1,4096:1:0`.

Example of applying an explicit product policy:

```sh
./run.sh --expect-services 64:1:1,4096:1:0
```

Do not copy that example into every target definition. First run the dynamic
default and inspect `qrtr_topology.tsv`. Add an expectation only when the
platform specification says its absence is a defect. CLI input overrides
`QRTR_EXPECT_SERVICES`; an empty value preserves automatic discovery without
target-specific requirements.

## Results and log markers

- `PASS`: a QRTR control-port lookup returns validated response rows, the
  topology is structurally valid, and all explicitly requested services exist.
- `FAIL`: lookup fails, output is malformed or duplicated, a requested service
  is absent, or persistent QRTR kernel errors are found.
- `SKIP`: QRTR is not applicable, neither lookup provider is runnable, or
  kernel logs alone are inaccessible.

Look for `[QRTR-POLICY]`, `[QRTR-RUNTIME]`, `[QRTR-DISCOVERY]`,
`[QRTR-FUNCTIONAL]`, `[QRTR-TOPOLOGY]`, and
`[QRTR-SERVICE]` in stdout. Each `[QRTR-SERVICE]` line identifies the service,
version, instance, node, and port that passed structural validation. Up to 64
endpoint rows are printed. Larger topologies report the omitted count and the
complete artifact path. Explicit policy checks are printed as
`[QRTR-EXPECTED]` rows.
`[QRTR-POLICY] mode=dynamic` confirms that no target-specific list was imposed.
The complete
`qrtr_lookup.log`, `qrtr_topology.tsv`, `qrtr_summary.env`, optional
`expected_services.tsv`, and `kernel/` evidence remain in the printed run
directory.

The fallback protocol follows the public `linux-msm/qrtr` implementation:
it sends `QRTR_TYPE_NEW_LOOKUP` to the local QRTR control port and decodes
`QRTR_TYPE_NEW_SERVER` responses. Service values remain target-derived; only
the public control packet constants are fixed.

Kernel health capture prefers `dmesg` and falls back to image-provided
`journalctl -k`; `kernel/dmesg_access.log` retains provider and permission
diagnostics.
