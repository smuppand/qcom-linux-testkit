# QPS615 traffic validation

`QPS615_Traffic_Validation` provides the external-fixture part of the QPS615
bring-up procedure. It reuses runtime PCIe, firmware, device-tree, driver, and
netdev correlation from the read-only interface test, then validates packet
transfer only after explicit operator opt-in.

The suite never assumes PCI BDFs or interface names, never installs packages,
and never changes link state, addresses, DHCP, or routes. Prepare the selected
interfaces before running it.

FIT-based targets must first run
`QPS615_Interface_Validation/run.sh --prepare-overlay`, reboot when requested,
and confirm that runtime QPS615 DT and PCI evidence is active.

## Fixture preparation and run

Connect the selected QPS615 port or ports to reachable peers. Configure link
carrier and IPv4. An interface-specific default gateway may be used as the
peer, or provide an explicit non-loopback unicast IPv4 address.

```sh
cd Runner/suites/Connectivity/Ethernet/QPS615_Traffic_Validation
./run.sh --fixture --peer 192.0.2.2
./run.sh --fixture --interfaces eth1,eth2 --peer 192.0.2.2
./run.sh --fixture --interfaces all --peer 192.0.2.2
```

Options:

| Option | Default | Purpose |
|---|---:|---|
| `--fixture [0\|1]` | `0` | Confirm that selected ports have reachable peers |
| `--interfaces LIST` | automatic | Select a comma-separated subset or `all` |
| `--peer IPV4` | interface gateway | Override per-interface gateway discovery |
| `--ping-count N` | `10` | Echo requests per interface, maximum `20` |
| `--ping-wait N` | `2` | Per-request wait in seconds, maximum `5` |

Automatic interface selection is accepted only when exactly one QPS615 netdev
exists. Multiple interfaces require `--interfaces` because software cannot
infer the lab wiring. Running without `--fixture` performs discovery and
returns an actionable `SKIP` without transmitting traffic.

The LAVA YAML exposes the same fixture, interface, peer, count, and wait
options. Its default `QPS615_TRAFFIC_FIXTURE=0` remains non-disruptive. A lab
job must set it to `1` and supply interface or peer overrides when automatic
discovery does not match the fixture wiring.

## Validation and result policy

Each selected interface must have carrier, a configured IPv4 address, a valid
peer, successful interface-bound ping with zero packet loss, increasing RX and
TX packet counters, and no growth in RX, TX, CRC, or carrier-error counters.
Once `--fixture` is selected, missing hardware, tools, carrier, address,
routing, or counter evidence is `FAIL` because the requested data path cannot
be proven. This keeps missing image content separate from unsupported-platform
skips.

Ping runs in the C locale with its native finite count and per-request wait.
Kernel logs are captured once through the shared diagnostic helper. Evidence
is retained under `results/QPS615_Traffic_Validation/run-*/`.

This focused suite closes the interface-selection gap by transmitting only on
netdevs dynamically correlated with QPS615 PCI functions. Throughput, UDP,
bidirectional, dual-port, and suspend/resume coverage remains in the existing
generic Ethernet suites. Operators should pass one of the correlated netdevs
reported by this suite to those tests rather than duplicating their data paths
here.
