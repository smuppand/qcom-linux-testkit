# Qualcomm interconnect provider validation

`Interconnect_Provider_Validation` verifies that enabled Qualcomm Linux
interconnect providers described by the runtime device tree have corresponding
platform devices, bind to a driver, and reach synchronized state when the
kernel exposes `state_synced`.

The test discovers providers dynamically through `#interconnect-cells`. It
does not assume a SoC name, provider address, driver name, or node count.

## Result policy

- `PASS`: every discovered provider has a bound driver and every exposed
  `state_synced` attribute contains `1`.
- `FAIL`: an enabled provider is missing, unbound, unsynchronized, or has a
  persistent ICC or NoC kernel error.
- `SKIP`: no applicable Qualcomm ICC provider exists. An individual
  `state_synced` check is also skipped when that optional ABI is unavailable.

Early `-EPROBE_DEFER` (`-517`) messages are not failures by themselves. Final
runtime binding is used to determine whether dependency resolution completed.

The suite is read-only. It never writes `state_synced`, because writing that
attribute forcibly invokes the provider callback independently of consumer
state.
