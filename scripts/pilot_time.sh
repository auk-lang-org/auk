#!/usr/bin/env bash
# Time the Rust front end against its Auk port (compiler/) on the golden corpus: lexing alone,
# then lexing + parsing, each in-process (`--time`, file reading excluded, `--repeat` passes
# per run) and as whole-process wall time with the dump written to /dev/null. Best of RUNS.
# Usage: scripts/pilot_time.sh [RUNS] [REPEAT]

source "$(dirname "$0")/pilot_common.sh"
RUNS="${1:-5}"
REPEAT="${2:-20}"
build_both
FILES=()
while read -r f; do FILES+=("$f"); done < <(find tests examples packages src/prelude -name '*.auk' | LC_ALL=C sort)
BYTES=$(cat "${FILES[@]}" | wc -c | tr -d ' ')
echo "corpus: ${#FILES[@]} files, $BYTES bytes; best of $RUNS runs"

# best_us CMD...: the smallest "time: N us" over RUNS runs
best_us() {
  local best=""
  for _ in $(seq "$RUNS"); do
    local t
    t=$("$@" 2>&1 >/dev/null | sed -n 's/^time: \([0-9]*\) us$/\1/p')
    if [ -z "$best" ] || [ "$t" -lt "$best" ]; then best="$t"; fi
  done
  echo "$best"
}

# best_wall_ms CMD...: the smallest wall time over RUNS runs, output discarded
best_wall_ms() {
  local best=""
  for _ in $(seq "$RUNS"); do
    local s e
    s=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000000')
    "$@" >/dev/null 2>&1 || true
    e=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000000')
    local t=$(((e - s) / 1000))
    if [ -z "$best" ] || [ "$t" -lt "$best" ]; then best="$t"; fi
  done
  echo "$best"
}

ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.2fx", a / b; else print "-" }'; }

printf '%-34s %12s %12s %8s\n' "measure" "Rust" "Auk" "Auk/Rust"
for mode in tokens ast; do
  r=$(best_us "$AUK" dump "$mode" --quiet --time --repeat "$REPEAT" "${FILES[@]}")
  a=$(best_us "$PORT" "$mode" --quiet --time --repeat "$REPEAT" "${FILES[@]}")
  printf '%-34s %10s us %10s us %8s\n' "$mode, in-process (per pass)" "$r" "$a" "$(ratio "$a" "$r")"
done
for mode in tokens ast; do
  r=$(best_wall_ms "$AUK" dump "$mode" "${FILES[@]}")
  a=$(best_wall_ms "$PORT" "$mode" "${FILES[@]}")
  printf '%-34s %10s ms %10s ms %8s\n' "$mode + dump, whole process" "$r" "$a" "$(ratio "$a" "$r")"
done
