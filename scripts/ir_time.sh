#!/usr/bin/env bash
# Time MIR lowering, Rust against the Auk port (docs/self-host-plan.md, Phase 3): for every
# program `auk ir` takes (the back end's corpus plus compiler/tests/ir/), the in-process time of
# lowering the typed program to MIR (imprints excluded: Rust `AUK_TIME_LOWER=1 auk ir`, the
# port's `compiler ir --time --quiet`), summed over the corpus; then the whole process (load,
# check, lower, print to /dev/null). Best of RUNS for each program.
# Usage: scripts/ir_time.sh [RUNS]
source "$(dirname "$0")/pilot_common.sh"
RUNS="${1:-3}"
build_both
out="$ROOT/target/pilot/ir_time"
mkdir -p "$out"
FILES=()
while read -r f; do FILES+=("$f"); done < <({ backend_corpus; grep -rlE '^(pub )?(async )?fn main\(' compiler/tests/ir 2>/dev/null; } | LC_ALL=C sort -u)
echo "corpus: ${#FILES[@]} programs; best of $RUNS runs each"
one_us() { "$@" 2>&1 >/dev/null | sed -n 's/^time: \([0-9]*\) us$/\1/p' | tail -1; }
one_ms() {
  local s e
  s=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000000')
  "$@" >/dev/null 2>&1 || true
  e=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000000')
  echo $(((e - s) / 1000))
}
min() { if [ -z "$1" ] || [ "$2" -lt "$1" ]; then echo "$2"; else echo "$1"; fi; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.2fx", a / b; else print "-" }'; }
lr=0 la=0 wr=0 wa=0
for f in "${FILES[@]}"; do
  key="${f//\//_}"
  rm -f "$out/$key.rec"
  AUK_IMPRINT_RECORDS="$out/$key.rec" "$AUK" ir "$f" >/dev/null 2>&1 || true
  imp=()
  if [ -f "$out/$key.rec" ]; then imp=(--imprints "$out/$key.rec"); fi
  r="" a="" r2="" a2=""
  for _ in $(seq "$RUNS"); do
    r=$(min "$r" "$(AUK_TIME_LOWER=1 one_us "$AUK" ir "$f")")
    a=$(min "$a" "$(one_us "$PORT" ir --time --quiet ${imp[@]+"${imp[@]}"} "$f")")
    r2=$(min "$r2" "$(one_ms "$AUK" ir "$f")")
    a2=$(min "$a2" "$(one_ms "$PORT" ir ${imp[@]+"${imp[@]}"} "$f")")
  done
  lr=$((lr + ${r:-0})) la=$((la + ${a:-0})) wr=$((wr + r2)) wa=$((wa + a2))
done
printf '%-34s %12s %12s %8s\n' "measure" "Rust" "Auk" "Auk/Rust"
printf '%-34s %9s ms %9s ms %8s\n' "lower, in-process (sum)" "$((lr / 1000))" "$((la / 1000))" "$(ratio "$la" "$lr")"
printf '%-34s %9s ms %9s ms %8s\n' "ir, whole process (sum)" "$wr" "$wa" "$(ratio "$wa" "$wr")"
