#!/usr/bin/env bash
# MIR round trip (docs/self-host-plan.md, Phase 4): for every back-end program and each
# `auk dump mir` variant, the Auk port reads the dump and prints the MIR as C-like text; it must
# equal `auk ir` with the same options.
source "$(dirname "$0")/pilot_common.sh"
build_both
out="$ROOT/target/pilot/mir"
rm -rf "$out"
mkdir -p "$out"
n=0 bad=0
while read -r f; do
  for v in "${BACKEND_VARIANTS[@]}"; do
    n=$((n + 1))
    key="${f//\//_}${v// /}"
    # shellcheck disable=SC2086  # the variant's options are words
    "$AUK" dump mir $v "$f" > "$out/$key.dump" 2>&1 || true
    # shellcheck disable=SC2086
    "$AUK" ir $v "$f" > "$out/$key.rust" 2>&1 || true
    "$PORT" mir "$out/$key.dump" > "$out/$key.auk" 2>&1 || true
    if ! cmp -s "$out/$key.rust" "$out/$key.auk"; then
      bad=$((bad + 1))
      echo "DIFF $f $v (diff $out/$key.rust $out/$key.auk)"
    fi
  done
done < <(backend_corpus)
echo "mir: $n dumps, $bad differ"
[ "$bad" -eq 0 ]
