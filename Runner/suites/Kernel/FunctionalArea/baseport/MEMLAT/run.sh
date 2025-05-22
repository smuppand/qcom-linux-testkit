#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
while [ "$ROOT_DIR" != "/" ]; do
    if [ -d "$ROOT_DIR/utils" ] && [ -d "$ROOT_DIR/suites" ]; then
        break
    fi
    ROOT_DIR=$(dirname "$ROOT_DIR")
done

if [ ! -d "$ROOT_DIR/utils" ] || [ ! -f "$ROOT_DIR/utils/functestlib.sh" ]; then
    echo "[ERROR] Could not detect testkit root (missing utils/ or functestlib.sh)" >&2
    exit 1
fi

TOOLS="$ROOT_DIR/utils"
INIT_ENV="$ROOT_DIR/init_env"
FUNCLIB="$TOOLS/functestlib.sh"

[ -f "$INIT_ENV" ] && . "$INIT_ENV"
. "$FUNCLIB"

__RUNNER_SUITES_DIR="${__RUNNER_SUITES_DIR:-$ROOT_DIR/suites}"

TESTNAME="MEMLAT"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

sync
sleep 1

log_info "Checking if dependency binary is available"
check_dependencies lat_mem_rd

extract_votes() {
  cat /sys/kernel/debug/interconnect/interconnect_summary | grep -i cpu | awk '{print $NF}'
}

log_info "Initial vote check:"
initial_votes=$(extract_votes)
log_info "$initial_votes"


log_info "Running lat_mem_rd tool..."
$test_bin_path -t 128MB 16 &

sleep 30
log_info "Vote check while bw_mem tool is running:"
final_votes=$(extract_votes)
log_info "$final_votes"

wait

log_info "Comparing votes..."

incremented=true
# shellcheck disable=SC2046
for i in $(seq 1 $(echo "$initial_votes" | wc -l)); do
  initial_vote=$(echo "$initial_votes" | sed -n "${i}p")
  final_vote=$(echo "$final_votes" | sed -n "${i}p")
  if [ "$final_vote" -le "$initial_vote" ]; then
    incremented=false
    log_pass "Vote did not increment for row $i: initial=$initial_vote, final=$final_vote"
  else
    log_fail "Vote incremented for row $i: initial=$initial_vote, final=$final_vote"
  fi
done

if $incremented; then
  log_pass "TEST PASSED."
else
  log_fail "TEST FAILED."
fi
if $incremented; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
