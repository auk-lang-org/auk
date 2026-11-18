#!/usr/bin/env bash
# Code generation time (MIR → LLVM IR, no passes), Rust back end vs its Auk port
# (docs/self-host-plan.md, Phase 4): best of N runs each, from AUK_TIME_BACKEND=1's report of the
# program's module (an imprint's helper module, compiled first, is skipped), plus the port's
# reading of the MIR dump.
# Usage: scripts/backend_time.sh [runs] [program...]   (default: 5 runs; a few corpus programs)
source "$(dirname "$0")/pilot_common.sh"
RUNS="${1:-5}"
shift || true
PROGS=("$@")
[ ${#PROGS[@]} -eq 0 ] && PROGS=(examples/hello.auk examples/tour.auk compiler/tests/backend/data.auk compiler/src/main.auk)
build_both
out="$ROOT/target/pilot/time"
mkdir -p "$out"
best() { sort -n | head -1; }
printf '%-34s %10s %10s %7s %10s %8s\n' program "rust us" "auk us" ratio "read us" "IR lines"
for f in "${PROGS[@]}"; do
  dump="$out/${f//\//_}.dump"
  "$AUK" dump mir "$f" > "$dump"
  r=$(for _ in $(seq "$RUNS"); do
        AUK_TIME_BACKEND=1 "$AUK" ir --llvm=o0-raw "$f" 2>&1 >/dev/null | grep '^backend:' | tail -1 \
          | sed 's/backend: codegen \([0-9]*\) us.*/\1/'
      done | best)
  a=$(for _ in $(seq "$RUNS"); do
        AUK_TIME_BACKEND=1 "$PORT" llvm --level o0-raw "$dump" 2>&1 >/dev/null | grep '^backend:' \
          | sed 's/backend: codegen \([0-9]*\) us.*/\1/'
      done | best)
  t=$(for _ in $(seq "$RUNS"); do
        "$PORT" mir --time "$dump" 2>&1 >/dev/null | sed 's/time: read \([0-9]*\) us.*/\1/'
      done | best)
  lines=$("$AUK" ir --llvm=o0-raw "$f" | wc -l | tr -d ' ')
  printf '%-34s %10s %10s %6.2fx %10s %8s\n' "$f" "$r" "$a" "$(echo "$a / $r" | bc -l)" "$t" "$lines"
done
echo "(read us: the port reading the MIR dump into its data structures, \`compiler mir --time\`)"
