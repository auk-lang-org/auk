# Shared by scripts/diff_tokens.sh and scripts/diff_ast.sh (the self-hosting pilot).
# Builds the Rust `auk` and the Auk port (compiler/), and lists the corpus.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
AUK="$ROOT/target/release/auk"
PORT="$ROOT/target/pilot/compiler"

build_both() {
  cargo build --release -q
  mkdir -p "$ROOT/target/pilot"
  "$AUK" build compiler/src/main.auk -o "$PORT"
}

# Every .auk the pilot is checked on: the golden corpus plus compiler/tests/ (error cases).
corpus() {
  find tests examples packages src/prelude compiler/src compiler/tests -name '*.auk' 2>/dev/null | LC_ALL=C sort
}

# diff_mode tokens|ast: dump every corpus file with both and report the files that differ.
diff_mode() {
  local mode="$1" out="$ROOT/target/pilot/$1" n=0 bad=0
  build_both
  rm -rf "$out"
  mkdir -p "$out"
  while read -r f; do
    n=$((n + 1))
    local key="${f//\//_}"
    "$AUK" dump "$mode" "$f" > "$out/$key.rust" 2>&1 || true
    "$PORT" "$mode" "$f" > "$out/$key.auk" 2>&1 || true
    if ! cmp -s "$out/$key.rust" "$out/$key.auk"; then
      bad=$((bad + 1))
      echo "DIFF $f ($(diff "$out/$key.rust" "$out/$key.auk" | grep -c '^[<>]') lines; diff $out/$key.rust $out/$key.auk)"
    fi
  done < <(corpus)
  echo "$mode: $n files, $bad differ"
  [ "$bad" -eq 0 ]
}
