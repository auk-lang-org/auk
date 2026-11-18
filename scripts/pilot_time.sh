#!/usr/bin/env bash
# Time the Rust front end against its Auk port (compiler/) on the golden corpus: lexing alone,
# then lexing + parsing, each in-process (`--time`, file reading excluded, `--repeat` passes
# per run) and as whole-process wall time with the dump written to /dev/null; then loading every
# file's program (`resolve`: the prelude, the project, its dependencies), and loading +
# type-checking it (`check`: check.rs, without patterns/effects), REPEAT/10 passes per run; the
# checker alone is the difference. Best of RUNS. tests/checker/ (small error cases) is left out
# so the numbers stay comparable with the earlier tables.
# Usage: scripts/pilot_time.sh [RUNS] [REPEAT]

source "$(dirname "$0")/pilot_common.sh"
RUNS="${1:-5}"
REPEAT="${2:-20}"
build_both
FILES=()
while read -r f; do FILES+=("$f"); done < <(find tests examples packages src/prelude -name '*.auk' -not -path '*/.raft/*' -not -path 'tests/checker/*' | LC_ALL=C sort)
BYTES=$(cat "${FILES[@]}" | wc -c | tr -d ' ')
echo "corpus: ${#FILES[@]} files, $BYTES bytes; best of $RUNS runs"

# one_us CMD...: the "time: N us" a run reports
one_us() { "$@" 2>&1 >/dev/null | sed -n 's/^time: \([0-9]*\) us$/\1/p'; }

# one_ms CMD...: a run's wall time, output discarded
one_ms() {
  local s e
  s=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000000')
  "$@" >/dev/null 2>&1 || true
  e=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000000')
  echo $(((e - s) / 1000))
}

min() { if [ -z "$1" ] || [ "$2" -lt "$1" ]; then echo "$2"; else echo "$1"; fi; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.2fx", a / b; else print "-" }'; }

# Rust and Auk runs alternate, so a busy machine slows both alike; each keeps its best.
printf '%-34s %12s %12s %8s\n' "measure" "Rust" "Auk" "Auk/Rust"
for mode in tokens ast resolve check; do
  r="" a="" n="$REPEAT"
  if [ "$mode" = resolve ] || [ "$mode" = check ]; then n=$(((REPEAT + 9) / 10)); fi
  for _ in $(seq "$RUNS"); do
    r=$(min "$r" "$(one_us "$AUK" dump "$mode" --quiet --time --repeat "$n" "${FILES[@]}")")
    a=$(min "$a" "$(one_us "$PORT" "$mode" --quiet --time --repeat "$n" "${FILES[@]}")")
  done
  printf '%-34s %10s us %10s us %8s\n' "$mode, in-process (per pass)" "$r" "$a" "$(ratio "$a" "$r")"
  eval "R_$mode=$r A_$mode=$a"
done
r=$((R_check - R_resolve)) a=$((A_check - A_resolve))
printf '%-34s %10s us %10s us %8s\n' "check alone (difference)" "$r" "$a" "$(ratio "$a" "$r")"
for mode in tokens ast resolve typed; do
  r="" a=""
  for _ in $(seq "$RUNS"); do
    r=$(min "$r" "$(one_ms "$AUK" dump "$mode" "${FILES[@]}")")
    a=$(min "$a" "$(one_ms "$PORT" "$mode" "${FILES[@]}")")
  done
  printf '%-34s %10s ms %10s ms %8s\n' "$mode + dump, whole process" "$r" "$a" "$(ratio "$a" "$r")"
done
# `fmt --check` of every file in one process: parse, format, re-parse the output and compare
# ASTs (`format_checked`), nothing written
r="" a=""
for _ in $(seq "$RUNS"); do
  r=$(min "$r" "$(one_ms "$AUK" fmt --check "${FILES[@]}")")
  a=$(min "$a" "$(one_ms "$PORT" fmt --check "${FILES[@]}")")
done
printf '%-34s %10s ms %10s ms %8s\n' "fmt --check, whole process" "$r" "$a" "$(ratio "$a" "$r")"
