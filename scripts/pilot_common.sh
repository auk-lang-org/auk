# Shared by scripts/diff_tokens.sh, diff_ast.sh and diff_resolve.sh (the self-hosting port).
# Builds the Rust `auk` and the Auk port (compiler/), and lists the corpus.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
AUK="$ROOT/target/release/auk"
PORT="$ROOT/target/pilot/compiler"

build_both() {
  cargo build --release -q
  # the port's dependency (packages/llvm, for the back end) and the runtime it embeds
  # (target/auk-rt/, written by the cargo build)
  [ -d compiler/.raft ] || (cd compiler && "$ROOT/target/release/raft" install >/dev/null)
  mkdir -p "$ROOT/target/pilot"
  "$AUK" build compiler/src/main.auk -o "$PORT"
}

# Every .auk the pilot is checked on: the golden corpus plus compiler/tests/ (error cases).
corpus() {
  find tests examples packages src/prelude compiler/src compiler/tests -name '*.auk' -not -path '*/.raft/*' 2>/dev/null | LC_ALL=C sort
}

# diff_mode tokens|ast|resolve: dump every corpus file with both and report the files that differ.
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

# diff_cmd NAME CMD [FLAG...]: run `auk CMD <file> FLAG...` and `compiler CMD <file> FLAG...` on
# every corpus file and compare stdout, stderr and the exit code (the command's whole visible
# behavior).
diff_cmd() {
  local name="$1" out="$ROOT/target/pilot/$1" n=0 bad=0
  shift
  build_both
  rm -rf "$out"
  mkdir -p "$out"
  while read -r f; do
    n=$((n + 1))
    local key="${f//\//_}"
    run_cmd "$out/$key.rust" "$AUK" "$1" "$f" "${@:2}"
    run_cmd "$out/$key.auk" "$PORT" "$1" "$f" "${@:2}"
    if ! cmp -s "$out/$key.rust" "$out/$key.auk"; then
      bad=$((bad + 1))
      echo "DIFF $f ($(diff "$out/$key.rust" "$out/$key.auk" | grep -c '^[<>]') lines; diff $out/$key.rust $out/$key.auk)"
    fi
  done < <(corpus)
  echo "$name: $n files, $bad differ"
  [ "$bad" -eq 0 ]
}

# run_cmd OUT CMD...: CMD's stdout, then its stderr, then its exit code, into OUT.
run_cmd() {
  local o="$1" rc=0
  shift
  "$@" > "$o.stdout" 2> "$o.stderr" || rc=$?
  { cat "$o.stdout"; echo "-- stderr"; cat "$o.stderr"; echo "-- exit $rc"; } > "$o"
  rm -f "$o.stdout" "$o.stderr"
}
# The back end's corpus (Phase 4): every program `auk ir` takes (golden.sh's `ir` mode: it checks
# clean and has a `main`), plus compiler/tests/backend/ (small programs for each MIR construct).
backend_corpus() {
  { find tests examples packages src/prelude compiler -name '*.auk' -not -path '*/.raft/*' \
      -not -path 'compiler/tests/backend/*' 2>/dev/null \
      | while read -r f; do
          if grep -Eq '^(pub )?(async )?fn main\(' "$f" \
              && "$AUK" check "$f" --json 2>/dev/null | head -1 | grep -q '"ok":true'; then
            echo "$f"
          fi
        done
    [ -d compiler/tests/backend ] && find compiler/tests/backend -name '*.auk'; true; } | LC_ALL=C sort
}

# The `auk dump mir` options each back-end program is diffed under: the MIR `auk run`/`ir`
# compiles, `auk build`'s (release), `auk build -g`'s, a traced run's and a debugger run's.
BACKEND_VARIANTS=("" "--release" "--release -g" "--trace=json" "--debug")
