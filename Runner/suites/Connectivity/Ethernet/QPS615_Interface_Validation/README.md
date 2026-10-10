# QPS615 interface validation

`QPS615_Interface_Validation` performs read-only QPS615 interface bring-up by
default, without hardcoded PCI BDFs or network-interface names. It correlates
enabled runtime device-tree nodes, the Toshiba `1179:0623` switch, downstream
`1179:0220` Ethernet functions, `tc956x_pcie_eth`, the registered
`tc956x_pci-eth` driver, and exported netdevs. An explicit option supports the
EFI selection required by FIT-based QPS615 device trees.

The runtime device tree is authoritative when it declares
`compatible = "pci1179,0623"`. A declared node with no enumerated switch is a
bring-up failure. An enumerated switch without a matching runtime DT node is
still validated for compatibility with older integrations.

The public qcom-next binding requires six supplies, `i2c-parent`, and
`resx-gpios` for the TC9563 PCI power-control flow. When a runtime node declares
any of those six supplies, the suite requires the complete supply set and the
node to bind to the `pwrctrl-tc9563` platform driver. Nodes that declare no
supplies remain valid for integrations such as the Talos staging topology that
do not instantiate this platform driver.

## Run

```sh
cd Runner/suites/Connectivity/Ethernet/QPS615_Interface_Validation
./run.sh
```

The default command discovers the platform's `VendorDtbOverlays` EFI variable
by name and checks for the QPS615 FIT compatibility value `staging`. An existing
unique variable supplies its GUID. Missing EFI tooling or a different value
does not invalidate a QPS615 instance proven by runtime DT and PCI evidence, because some
boards provide QPS615 directly in their base DT.

On a QPS615 target that boots selectable DTBs from a FIT image, prepare the
next boot explicitly:

```sh
./run.sh --prepare-overlay
```

This option requires image-provided `efivar`, mount utilities, and EFI runtime
services. If efivarfs is unmounted, it mounts the existing EFI variable-storage
directory and leaves it mounted. This follows the manual procedure:

```sh
mount | grep efivar
# If no efivarfs mount is listed:
mount -t efivarfs none /sys/firmware/efi/efivars
```

An existing mount typically appears as
`none on /sys/firmware/efi/efivars type efivarfs (rw,relatime)`.
If a successful EFI inventory shows no
`VendorDtbOverlays`, explicit preparation creates it using the documented
QPS615 firmware GUID `882f8c2b-9646-435f-8de5-f208ff80c1bd`. Failed inventory,
ambiguous names, and unreadable variables prevent writes and report failure.

If `staging` is not selected, this command writes and verifies it, records
`SKIP`, and asks
the operator to reboot manually. It never reboots the target. After reboot,
rerun the same command. An already selected FIT value followed by missing
runtime QPS615 DT and PCI evidence is then a failure, exposing a FIT image,
firmware, or boot-integration problem.

Preparation never unmounts efivarfs. A newly created mount remains available
after success, write/read failures, or interruption. Cleanup only restores an
initially read-only mount after a temporary read-write remount, including on
failure or interruption. Initially read-write mounts remain read-write.
Read-only restoration failure makes preparation fail even if the EFI write
succeeded.

The LAVA YAML intentionally runs only the read-only default command. EFI
mutation is not exposed as an automated parameter. Neither mode changes
network configuration, routes, or link state.

## Validation and classification

The suite validates:

- enabled `pci1179,0623` DT nodes and their complete compatible strings;
- conditional `pwrctrl-tc9563` platform-device binding;
- PCI switch and downstream endpoint enumeration, reporting outermost
  `1179:0623` switch roots separately from all matching bridge functions;
- `TC956X_Firmware_PCIeBridge.bin` provisioning;
- TC956x module and PCI-driver readiness;
- runtime DT Ethernet-port declarations and dynamic netdev correlation;
- optional non-mutating `ethtool` driver and link diagnostics;
- captured kernel health through the shared dmesg scanner.

Carrier and IPv4 are readiness evidence and do not fail this suite because
they depend on external wiring and lab network configuration.

- `PASS`: applicable DT, power-control, PCIe, firmware, driver, and netdev
  checks are healthy.
- `FAIL`: declared hardware does not enumerate, the supply-backed DT contract
  is partial or unbound, an explicitly selected FIT value does not become
  active, EFI preparation fails, required firmware or driver readiness is
  broken, or an image-provided diagnostic tool fails on an interface.
- `SKIP`: no enabled QPS615 DT node or enumerated switch is present, no
  Ethernet port is provisioned, a newly written FIT value requires reboot, or
  optional EFI inspection, carrier, IPv4, or `ethtool` evidence is absent.

The suite installs no packages and is portable across Yocto, Debian, Ubuntu,
and CentOS. Evidence is retained under
`results/QPS615_Interface_Validation/run-*/`, including
`qps615_runtime/qps615_runtime.tsv`, `qps615_dt_nodes.log`,
`qps615_dt_platform.tsv`, `qps615_overlay.tsv`, EFI diagnostics, PCI topology,
`ethtool`, and captured kernel logs.
EFI preparation retains `before_qps615_overlay.tsv`, the original variable
inventory and printout, and mount/cleanup logs alongside the updated evidence.

For the guide's one upstream and three downstream `0623` bridges, the runtime
summary reports `switches=1 bridge_functions=4`. Separate PCI hierarchies are
counted independently. A switch-root group includes any nested `0623` bridges,
so this count describes the discovered topology roots.

For host regression checks, run `dash scripts/tests/qps615-helpers.sh` from
the repository root. The checks use temporary PCI fixtures and mock all EFI
commands and mount operations. They validate helper behavior, not hardware.

## Public driver references

- [qcom-next TC9563 binding](https://github.com/qualcomm-linux/kernel/blob/qcom-next/Documentation/devicetree/bindings/pci/toshiba%2Ctc9563.yaml)
- [qcom-next TC9563 power-control driver](https://github.com/qualcomm-linux/kernel/blob/qcom-next/drivers/pci/pwrctrl/pci-pwrctrl-tc9563.c)
- [kernel-topics QPS615 pull requests](https://github.com/search?q=repo%3Aqualcomm-linux%2Fkernel-topics+qps615&type=pullrequests)
- [QCS8550 RB5Gen2 base-DT integration](https://github.com/qualcomm-linux/kernel-topics/commit/33cae252054a694269f9dcd41b354063193c8f59)

Use `QPS615_Traffic_Validation` for fixture-gated interface-bound ping and
counter movement. Use the existing generic Ethernet capability, throughput,
bidirectional, dual-port, and suspend/resume suites for their respective
end-use cases after selecting a QPS615-correlated interface.
