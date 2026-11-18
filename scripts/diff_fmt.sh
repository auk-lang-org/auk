#!/usr/bin/env bash
# Diff `auk fmt -` of the Rust compiler and its Auk port (`compiler fmt -`) over the corpus
# (see docs/self-host-plan.md, Phase 5): stdout, stderr and exit code for every file. Then check
# idempotence for both: formatting the formatted output changes nothing.
source "$(dirname "$0")/pilot_common.sh"
build_both
out="$ROOT/target/pilot/fmt"
rm -rf "$out"
mkdir -p "$out"
n=0 bad=0 unstable=0
# run <bin> <input> <prefix>: stdout to prefix.out, then stderr and the exit code to prefix.all
run() {
  local code=0
  "$1" fmt - < "$2" > "$3.out" 2> "$3.err" || code=$?
  { cat "$3.out"; echo "=== stderr ==="; cat "$3.err"; echo "=== exit $code ==="; } > "$3.all"
  return "$code"
}
while read -r f; do
  n=$((n + 1))
  key="$out/${f//\//_}"
  rc=0 ac=0
  run "$AUK" "$f" "$key.rust" || rc=$?
  run "$PORT" "$f" "$key.auk" || ac=$?
  if ! cmp -s "$key.rust.all" "$key.auk.all"; then
    bad=$((bad + 1))
    echo "DIFF $f ($(diff "$key.rust.all" "$key.auk.all" | grep -c '^[<>]') lines; diff $key.rust.all $key.auk.all)"
  fi
  # idempotence: format the output again
  for side in rust auk; do
    bin="$AUK"; code=$rc
    if [ "$side" = auk ]; then bin="$PORT"; code=$ac; fi
    [ "$code" -eq 0 ] || continue
    run "$bin" "$key.$side.out" "$key.$side.again" || true
    if ! cmp -s "$key.$side.out" "$key.$side.again.out" || [ -s "$key.$side.again.err" ]; then
      unstable=$((unstable + 1))
      echo "UNSTABLE ($side) $f (diff $key.$side.out $key.$side.again.out)"
    fi
  done
done < <(find tests examples packages compiler -name '*.auk' -not -path '*/.raft/*' | LC_ALL=C sort)
echo "fmt: $n files, $bad differ, $unstable not idempotent"
[ "$bad" -eq 0 ] && [ "$unstable" -eq 0 ]
