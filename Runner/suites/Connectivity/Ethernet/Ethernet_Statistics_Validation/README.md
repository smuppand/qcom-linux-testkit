# Ethernet_Statistics_Validation

## Overview

This testcase generates a bounded ICMP workload on each linked Ethernet interface and validates that standard Linux RX/TX byte and packet counters increase. It also checks counter deltas for errors and drops, avoiding false failures caused by historical counters accumulated before the testcase starts.

## Coverage

For every interface with carrier and a valid IPv4 address:

- interface-bound ping traffic
- RX byte delta
- TX byte delta
- RX packet delta
- TX packet delta
- RX error delta
- TX error delta
- RX drop delta
- TX drop delta
- filtered `ethtool -S` diagnostic output

## Configuration

CLI options override environment variables.

| CLI option | Environment variable | Default | Description |
|---|---|---:|---|
| `--link-timeout` | `LINK_TIMEOUT_S` | `10` | Maximum wait for carrier |
| `--ip-timeout` | `IP_TIMEOUT_S` | `15` | Maximum wait for IPv4 |
| `--interface` | `ETH_INTERFACE` | automatic | Explicit interface, otherwise auto-detect |
| `--ping-target` | `PING_TARGET` | automatic | Interface gateway or `8.8.8.8` |
| `--ping-count` | `PING_COUNT` | `10` | ICMP packets used for the workload |
| `--ping-wait` | `PING_WAIT_S` | `2` | Per-packet timeout |
| `--max-rx-error-delta` | `MAX_RX_ERROR_DELTA` | `0` | Allowed RX error increase |
| `--max-tx-error-delta` | `MAX_TX_ERROR_DELTA` | `0` | Allowed TX error increase |
| `--max-rx-drop-delta` | `MAX_RX_DROP_DELTA` | disabled | Allowed RX drop increase |
| `--max-tx-drop-delta` | `MAX_TX_DROP_DELTA` | disabled | Allowed TX drop increase |

Disconnected interfaces or interfaces without a valid IPv4 are skipped. Any
tested interface with missing counter movement or excessive new errors fails
the testcase. Drop deltas are reported as SKIP by default because unrelated
traffic can change them. Configure both drop thresholds to enforce them.

## Prerequisites and infrastructure

- The target image must provide `ip` and `ping`.
- Connect each tested interface to an active network with IPv4 configured.
- The automatic gateway or explicit `PING_TARGET` must reply to ICMP through
  the selected interface.
- Minimize unrelated traffic when enforcing drop thresholds. Standard Linux
  `rx_dropped` and `tx_dropped` counters are interface-wide and cannot be
  attributed solely to this testcase workload.
- Configure both `MAX_RX_DROP_DELTA` and `MAX_TX_DROP_DELTA` to enable strict
  drop enforcement. Leaving both empty keeps the check informational.

Example with strict drop thresholds:

```sh
./run.sh --max-rx-drop-delta 100 --max-tx-drop-delta 10
```

Use `./run.sh` to validate every detected physical interface, or select one:

```sh
./run.sh --interface end0 --ping-target 192.168.1.1
```

## Result

```text
Ethernet_Statistics_Validation.res
Ethernet_Statistics_Validation.results.tsv
```
