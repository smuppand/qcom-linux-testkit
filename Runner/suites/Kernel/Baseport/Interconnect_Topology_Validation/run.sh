#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
TESTNAME="Interconnect_Topology_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

providers_file="$SCRIPT_DIR/icc_provider_nodes.log"
graph_file="$SCRIPT_DIR/interconnect_graph.log"
summary_file="$SCRIPT_DIR/interconnect_summary.log"
nodes_file="$SCRIPT_DIR/interconnect_graph_nodes.log"
endpoints_file="$SCRIPT_DIR/interconnect_graph_endpoints.log"
: >"$providers_file"

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cp sed sort uniq grep awk wc find readlink dirname basename tr mktemp; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

if ! dt_list_qcom_icc_provider_nodes >"$providers_file"; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no enabled Qualcomm ICC provider is present in the runtime device tree"
fi
if [ ! -s "$providers_file" ]; then
    test_result_finish "FAIL" "$TESTNAME FAIL: ICC provider discovery returned no readable provider list"
fi

if ! debugfs_dir=$(interconnect_debugfs_dir); then
    test_result_finish "SKIP" "$TESTNAME SKIP: ICC debugfs summary and graph are not available"
fi

if ! cp "$debugfs_dir/interconnect_graph" "$graph_file" ||
   ! cp "$debugfs_dir/interconnect_summary" "$summary_file"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: ICC debugfs files could not be captured"
fi

sed -n 's/^[[:space:]]*"\([^"]*\)" \[label=.*/\1/p' "$graph_file" |
    sort -u >"$nodes_file"

{
    sed -n 's/^[[:space:]]*"\([^"]*\)" -> ".*/\1/p' "$graph_file"
    sed -n 's/^[[:space:]]*"[^"]*" -> "\([^"]*\)".*/\1/p' "$graph_file"
} | sort -u >"$endpoints_file"

provider_count=$(grep -c '^' "$providers_file" 2>/dev/null || true)
node_count=$(grep -c '^' "$nodes_file" 2>/dev/null || true)
edge_count=$(grep -c -- ' -> ' "$graph_file" 2>/dev/null || true)
provider_count=${provider_count:-0}
node_count=${node_count:-0}
edge_count=${edge_count:-0}
summary_node_count=$(awk '
    NR > 2 && $0 !~ /^[[:space:]][[:space:]]/ && NF >= 3 {
        count++
    }
    END {
        print count + 0
    }
' "$summary_file")

log_info "ICC topology totals: runtime_providers=$provider_count graph_nodes=$node_count graph_edges=$edge_count summary_nodes=$summary_node_count"

if grep -q '^digraph {' "$graph_file" && grep -q '^}' "$graph_file"; then
    test_result_record "PASS" "ICC graph has complete DOT framing"
else
    test_result_record "FAIL" "ICC graph is incomplete or malformed"
fi

if [ "$node_count" -gt 0 ]; then
    test_result_record "PASS" "ICC graph contains registered nodes: count=$node_count"
else
    test_result_record "FAIL" "ICC graph contains no registered nodes"
fi

if [ "$edge_count" -gt 0 ]; then
    test_result_record "PASS" "ICC graph contains topology links: count=$edge_count"
else
    test_result_record "FAIL" "ICC graph contains no topology links"
fi

dangling_count=0
while IFS= read -r endpoint; do
    [ -n "$endpoint" ] || continue
    if ! grep -Fqx "$endpoint" "$nodes_file"; then
        log_fail "ICC graph edge references an undeclared node: $endpoint"
        dangling_count=$((dangling_count + 1))
    fi
done <"$endpoints_file"

if [ "$dangling_count" -eq 0 ]; then
    test_result_record "PASS" "ICC graph contains no dangling edge references"
else
    test_result_record "FAIL" "ICC graph contains dangling edge references: count=$dangling_count"
fi

duplicate_id_count=$(sed 's/:.*//' "$nodes_file" | sort | uniq -d | wc -l | awk '{print $1}')
if [ "$duplicate_id_count" -eq 0 ]; then
    test_result_record "PASS" "ICC graph node IDs are unique"
else
    test_result_record "FAIL" "ICC graph contains duplicate node IDs: count=$duplicate_id_count"
fi

if [ "$summary_node_count" -eq "$node_count" ] && [ "$node_count" -gt 0 ]; then
    test_result_record "PASS" "ICC summary and graph expose the same node count"
else
    test_result_record "FAIL" "ICC summary and graph node counts differ: summary=$summary_node_count graph=$node_count"
fi

test_result_finish
