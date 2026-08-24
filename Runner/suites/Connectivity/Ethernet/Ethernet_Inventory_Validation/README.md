# Ethernet_Inventory_Validation

## Overview

This testcase performs a read-only inventory of every enumerated physical Ethernet interface. It is intended to establish whether the MAC, PHY, driver, device-tree node, queue layout, and associated platform resources are visible before running link or traffic tests.

## Coverage

For each interface, the testcase reports and validates:

- physical network-interface enumeration
- MAC address and MTU
- driver and kernel-module binding
- device and bus path
- firmware version when reported by the driver
- OF compatible string when exposed
- PHY identifier when exposed
- carrier, operational state, speed, and duplex
- RX and TX queue enumeration
- relevant kernel probe messages

The testcase does not bring interfaces up, run DHCP, change link settings, or transmit traffic.

## Prerequisites and infrastructure

- No cable, peer, DHCP service, or Internet connection is required.
- The target must expose the interface through `/sys/class/net` with a bound
  physical device.
- Standard image utilities such as `find`, `readlink`, `awk`, and `grep` must
  be present.
- `ethtool` data is collected when available, but optional properties that the
  driver does not expose are reported as SKIP.

## Run

```sh
cd Runner/suites/Connectivity/Ethernet/Ethernet_Inventory_Validation
./run.sh
./run.sh --help
```

Use `--interface IFACE` or `ETH_INTERFACE` to inspect one explicit interface.
When neither is provided, the suite uses the shared Ethernet discovery helper
and inventories every detected physical interface. CLI options override
environment variables.

Example:

```sh
./run.sh --interface end0
```

## Result

```text
Ethernet_Inventory_Validation.res
Ethernet_Inventory_Validation.results.tsv
```

The testcase passes when at least one physical Ethernet interface is enumerated with a bound driver and valid RX/TX queue entries. Optional OF and PHY properties are reported as SKIP when the corresponding bus or driver does not expose them.
