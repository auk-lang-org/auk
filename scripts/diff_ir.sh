#!/usr/bin/env bash
# MIR lowering (docs/self-host-plan.md, Phase 3): for every program `auk ir` takes (the back
# end's corpus plus compiler/tests/ir/) and each of its variants (run, --release, --release -g,
# --trace=json, --debug), the Auk port's `compiler ir` must print exactly what `auk ir` prints.
# The port can't run the imprint helper yet (that needs the back end): the Rust run writes the
# helper's records (AUK_IMPRINT_RECORDS) for the port to read, and the helper program itself
# (AUK_IMPRINT_EVAL_IR), which is diffed against the port's `ir --imprint-eval`.
# Usage: scripts/diff_ir.sh [--only REGEX]
source "$(dirname "$0")/pilot_common.sh"
only=""
if [ "${1:-}" = "--only" ]; then only="$2"; fi
build_both
out="$ROOT/target/pilot/ir"
rm -rf "$out"
mkdir -p "$out"
n=0 bad=0 evals=0
while read -r f; do
  if [ -n "$only" ] && ! [[ "$f" =~ $only ]]; then continue; fi
  for v in "${BACKEND_VARIANTS[@]}"; do
    n=$((n + 1))
    key="${f//\//_}${v// /}"
    rm -f "$out/$key.rec" "$out/$key.eval.rust"
    # shellcheck disable=SC2086  # the variant's options are words
    AUK_IMPRINT_RECORDS="$out/$key.rec" AUK_IMPRINT_EVAL_IR="$out/$key.eval.rust" \
      "$AUK" ir $v "$f" > "$out/$key.rust" 2>&1 || true
    imp=()
    if [ -f "$out/$key.rec" ]; then imp=(--imprints "$out/$key.rec"); fi
    # shellcheck disable=SC2086
    "$PORT" ir $v ${imp[@]+"${imp[@]}"} "$f" > "$out/$key.auk" 2>&1 || true
    if ! cmp -s "$out/$key.rust" "$out/$key.auk"; then
      bad=$((bad + 1))
      echo "DIFF $f $v (diff $out/$key.rust $out/$key.auk)"
    fi
    if [ -f "$out/$key.eval.rust" ] && [ -z "$v" ]; then
      evals=$((evals + 1))
      "$PORT" ir --imprint-eval "$f" > "$out/$key.eval.auk" 2>&1 || true
      if ! cmp -s "$out/$key.eval.rust" "$out/$key.eval.auk"; then
        bad=$((bad + 1))
        echo "DIFF $f imprint helper (diff $out/$key.eval.rust $out/$key.eval.auk)"
      fi
    fi
  done
done < <({ backend_corpus; grep -rlE '^(pub )?(async )?fn main\(' compiler/tests/ir 2>/dev/null; } | LC_ALL=C sort -u)
echo "ir: $n programs x variants, $evals imprint helpers, $bad differ"
[ "$bad" -eq 0 ]
