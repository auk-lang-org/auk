#!/usr/bin/env bash
# Diff the hidden debug commands `auk parse <file>`, `auk parse --ast <file>`, `auk parse --json
# <file>` and `auk typed <file>` (stdout, stderr, exit code), Rust compiler against its Auk port,
# over the corpus.
source "$(dirname "$0")/pilot_common.sh"

# diff_pre NAME CMD [FLAG...]: like `diff_cmd`, with the flags before the file
# (`auk CMD FLAG... <file>`).
diff_pre() {
  local name="$1" out="$ROOT/target/pilot/$1" n=0 bad=0
  shift
  rm -rf "$out"
  mkdir -p "$out"
  while read -r f; do
    n=$((n + 1))
    local key="${f//\//_}"
    run_cmd "$out/$key.rust" "$AUK" "$@" "$f"
    run_cmd "$out/$key.auk" "$PORT" "$@" "$f"
    if ! cmp -s "$out/$key.rust" "$out/$key.auk"; then
      bad=$((bad + 1))
      echo "DIFF $f ($(diff "$out/$key.rust" "$out/$key.auk" | grep -c '^[<>]') lines; diff $out/$key.rust $out/$key.auk)"
    fi
  done < <(corpus)
  echo "$name: $n files, $bad differ"
  [ "$bad" -eq 0 ]
}

build_both
status=0
diff_pre cmd_parse parse || status=1
diff_pre cmd_parse_ast parse --ast || status=1
diff_pre cmd_parse_json parse --json || status=1
diff_pre cmd_typed typed || status=1
exit $status
