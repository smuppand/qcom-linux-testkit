# QPS615 traffic validation

`QPS615_Traffic_Validation` extends the merged read-only QPS615 topology and
firmware checks with fixture-aware Ethernet traffic. It reuses the QPS615 PCIe
correlation helper, tests only netdevs belonging to enumerated QPS615 Ethernet
functions, and never assumes an interface name.

QPS615 applicability, PCIe functions, and associated netdevs are discovered
from the running target. Interface names and port counts can differ between
boards, so they are never hardcoded in the suite or YAML.

## Fixture and network preparation

Connect each selected port to a reachable peer or network. Configure carrier,
IPv4, and an interface-specific default gateway before running the suite, or
provide a non-loopback IPv4 address with `--peer`. The peer cannot be the
selected interface's own address, multicast, or in the reserved 240/4 range.
The test does not bring links up, run DHCP, or change routes.
It uses an image-provided `ping` plus `ip` or `ifconfig` for read-only network
discovery. Automatic gateway selection specifically requires `ip`; when it is
absent, provide `--peer` or the suite skips without installing packages.

```sh
./run.sh --fixture --peer 192.0.2.2
./run.sh --fixture --interfaces eth1,eth2 --peer 192.0.2.2
./run.sh --fixture --interfaces all --peer 192.0.2.2
```

Automatic selection is accepted only when exactly one QPS615 netdev exists.
With multiple ports, explicitly select the fixture-connected interfaces.
The fixture itself cannot be inferred from software, so `--fixture` is a
required operator or lab-policy confirmation before traffic is generated.

| Option | Environment | Default |
|---|---|---:|
| `--fixture [0\|1]` | `QPS615_TRAFFIC_FIXTURE` | `0` |
| `--interfaces` | `QPS615_INTERFACES` | unique auto-selection |
| `--peer` | `QPS615_PEER` | interface default gateway |
| `--ping-count` | `QPS615_PING_COUNT` | `10` |
| `--ping-wait` | `QPS615_PING_WAIT` | `2` seconds |

Leave `--interfaces` empty for dynamic unique selection. Use an explicit list
only when multiple discovered QPS615 ports exist and the test definition knows
which ports are wired. Leave `--peer` empty to use the selected interface's
default gateway; override it only when the fixture defines a different reachable
IPv4 peer. These overrides describe lab wiring and network policy, not SoC
identity.

## Validation

For every selected interface the suite requires carrier, configured IPv4,
successful interface-bound ping, increasing RX and TX packet counters, and no
packet loss or increase in RX, TX, CRC, or carrier-error counters. Once the
fixture is selected, missing carrier, IPv4 configuration, or peer routing is a
test failure rather than an unsupported-platform skip. Missing or malformed
counter attributes also fail because the suite cannot prove the data path or
error-free transfer without them. Look for
`[QPS615-POLICY]`, `[QPS615-RUNTIME]`, `[QPS615-AVAILABLE-INTERFACE]`,
`[QPS615-SELECTION]`, `[QPS615-SELECTED-INTERFACE]`, `[QPS615-TRAFFIC]`,
`[QPS615-PING-*]`, and `[QPS615-COUNTERS]`. Counter logs include the complete
before and after values as well as deltas. Runtime and command excerpts are
bounded and point to the complete retained artifact when additional lines exist.
`[QPS615-POLICY]` records automatic versus explicit interface and peer policy.
Topology, ping, counter, and kernel evidence remains under
`results/QPS615_Traffic_Validation/run-*/`.

Kernel health capture prefers `dmesg` and falls back to image-provided
`journalctl -k`; `kernel/dmesg_access.log` retains provider and permission
diagnostics.
