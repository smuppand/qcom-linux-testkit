# Interconnect topology validation

`Interconnect_Topology_Validation` validates the topology exported by the
Linux interconnect core through debugfs. It checks that the graph is complete,
contains nodes and links, has unique node IDs, has no dangling edge targets,
and agrees with the node count in `interconnect_summary`.

The captured files are retained as `interconnect_graph.log` and
`interconnect_summary.log` for LAVA triage.

## Requirements and result policy

The kernel must expose:

```text
/sys/kernel/debug/interconnect/interconnect_graph
/sys/kernel/debug/interconnect/interconnect_summary
```

The suite returns `SKIP` when Qualcomm ICC hardware is not applicable or when
debugfs is unavailable. Debugfs absence is not treated as a driver failure
because production images may disable it.

The suite is read-only. The upstream writable ICC debugfs test client is not
used because arbitrary bandwidth requests can affect system stability.
