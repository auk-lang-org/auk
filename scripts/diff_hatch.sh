#!/usr/bin/env bash
# Diff `auk hatch` (Rust) and its Auk port (`compiler hatch`, compiler/src/hatch.auk; see
# docs/self-host-plan.md, Phase 5): run the same scenarios with each, in the same scratch
# directory one after the other, with a scripted model (AUK_HATCH_CMD runs ./model.sh, which
# saves each prompt as prompt.N and replies with answers/N), and compare every command's stdout,
# stderr and exit code, and the whole tree after it (the fixed sources, every prompt).
#
# Usage: scripts/diff_hatch.sh [--slow]   (--slow: also an answer that loops forever, which
#                                          each side kills after its 60 s test timeout)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
cargo build --release -q
mkdir -p "$ROOT/target/pilot"
"$ROOT/target/release/auk" build compiler/src/main.auk -o "$ROOT/target/pilot/compiler"
RUST=("$ROOT/target/release/auk" hatch)
PORT=("$ROOT/target/pilot/compiler" hatch)
OUT="$ROOT/target/pilot/hatch-diff"
rm -rf "$OUT"
mkdir -p "$OUT"
W="$OUT/work" # the scenarios' directory, the same path for both binaries
SLOW="${1:-}"

# step <dir> <args...>: one hatch command in <dir> (AUK_HATCH_CMD from $CMD), its output and the
# tree after it, into $LOG.
step() {
  local dir="$1" rc=0
  shift
  (cd "$W/$dir" && AUK_HATCH_CMD="$CMD" "${BIN[@]}" "$@") > "$OUT/stdout" 2> "$OUT/stderr" || rc=$?
  {
    echo "== ($dir) [$CMD] hatch $*"
    cat "$OUT/stdout"
    echo "-- stderr"
    cat "$OUT/stderr"
    echo "-- exit $rc"
    (cd "$W" && find . -type f | LC_ALL=C sort | while read -r f; do echo "$(shasum -a 256 < "$f" | cut -c1-16) $f"; done)
  } >> "$LOG"
}

# new <dir>: a fresh scenario directory with the scripted model and calc.auk.
new() {
  mkdir -p "$W/$1/answers"
  cat > "$W/$1/model.sh" << 'EOF'
n=$(($(cat calls 2> /dev/null || echo 0) + 1))
echo "$n" > calls
cat > "prompt.$n"
if [ -f "answers/$n" ]; then . "./answers/$n"; else echo "no answer $n" >&2; exit 1; fi
EOF
  cat > "$W/$1/calc.auk" << 'EOF'
/// The sum of the squares of `xs`.
fn sum_sq(xs: [int]): int
  ensures result >= 0
{ ?? }

fn double(n: int): int = ??

/// The label of a score.
fn label(n: int): str {
  let base = if n > 9 { "big" } else { "small" }
  let tag: str = ??
  "{base}-{tag}"
}

fn main() {
  print(sum_sq([1, 2, 3]))
}

test "sum_sq" { assert sum_sq([1, 2, 3]) == 14 }
test "sum_sq of doubles" { assert sum_sq([double(1)]) == 4 }
test "double" { assert double(4) == 8 }
test "label" { assert label(12) == "big-12" }
EOF
}

# answer <dir> <n>: answers/<n> is the model's reply to its n-th prompt (a shell snippet).
answer() { cat > "$W/$1/answers/$2"; }

# reply <dir> <n> <text>: the n-th reply prints <text>.
reply() { printf 'cat << '"'"'END'"'"'\n%s\nEND\n' "$3" > "$W/$1/answers/$2"; }

scenario() {
  rm -rf "$W"
  mkdir -p "$W"
  CMD="sh ./model.sh"
  # usage errors, files that can't be hatched
  new args
  printf 'fn main() { print(1) }\n' > "$W/args/none.auk"
  printf 'fn main() { let x: int = "a"\n  print(??) }\n' > "$W/args/bad.auk"
  printf 'fn main() { print(1 +) }\n' > "$W/args/syntax.auk"
  step args
  step args --dry-run
  step args --hole
  step args calc.auk --hole
  step args --hole 0 calc.auk
  step args --hole x calc.auk
  step args --hole -1 calc.auk
  step args --tries 0 calc.auk
  step args --tries " 2" calc.auk
  step args --tries 99999999999999999999 calc.auk
  step args calc.auk --frob
  step args calc.auk other.auk
  step args -x
  step args calc.auk --hole 9
  step args --hole 4 calc.auk --dry-run
  step args missing.auk
  step args none.auk
  step args bad.auk
  step args syntax.auk
  step args .
  # every hole filled at the first try: a fenced block body, a plain fence, an unfenced and
  # indented multi-line expression
  new ok
  reply ok 1 'Here it is:
```auk
  var s = 0
  for x in xs {
    s += x * x
  }

  s
```
Hope that helps.'
  reply ok 2 '```
n * 2
```'
  reply ok 3 '    if n > 9 {
      "{n}"
    } else { "none" }'
  step ok calc.auk
  step ok calc.auk
  # the same as a dry run (a diff, no change), then one hole
  new dry
  cp "$W/ok/answers/"* "$W/dry/answers/"
  step dry calc.auk --dry-run
  rm "$W/dry/calls"
  step dry --hole 2 --dry-run calc.auk
  # retries: a type error, a `??` left in, an empty reply (hole 1 fails after 3 tries); a test
  # that fails (with its trace) then passes; then a model that fails
  new retry
  reply retry 1 '```auk
"no"
```'
  reply retry 2 '```auk
let a = ??
a
```'
  reply retry 3 'nothing here
```auk
```'
  reply retry 4 '```auk
n + 3
```'
  reply retry 5 '```auk
n * 2
```'
  answer retry 6 << 'EOF'
printf 'bad \377 bytes\n' >&2
exit 3
EOF
  cp "$W/retry/answers/6" "$W/retry/answers/7"
  cp "$W/retry/answers/6" "$W/retry/answers/8"
  step retry calc.auk
  # --tries 1 and --hole N; a failing test only through another unfilled hole doesn't count
  new tries
  reply tries 1 '```auk
xs.map(x => x * x).sum()
```'
  echo 'kill -9 $$' | answer tries 2
  step tries calc.auk --tries 1 --hole 1
  step tries calc.auk --tries 1 --hole 2
  step tries --tries 2 --hole 3 calc.auk
  echo "exit 1" | answer tries 3
  step tries --hole 1 calc.auk --tries 1
  # tests that fail with contracts: ensures broken, then a panic, then a wrong value
  new contracts
  reply contracts 1 '```auk
0 - 1
```'
  reply contracts 2 '```auk
xs[10]
```'
  reply contracts 3 '```auk
xs.len()
```'
  reply contracts 4 '```auk
sum_sq(xs) + 1
```'
  reply contracts 5 '```auk
xs.reduce(0, (a, x) => a + x * x)
```'
  step contracts calc.auk --hole 1 --tries 5
  # the model command itself: missing, failing with no stderr, the default (`claude -p`, here a
  # fake on PATH) for an unset or blank AUK_HATCH_CMD
  new cmds
  mkdir -p "$W/cmds/bin"
  printf '#!/bin/sh\ncat > /dev/null\necho "claude was asked: $*"\nexit 1\n' > "$W/cmds/bin/claude"
  chmod +x "$W/cmds/bin/claude"
  CMD="no-such-model-cmd --x"
  step cmds calc.auk --hole 2 --tries 2
  CMD="exit 4"
  step cmds calc.auk --hole 2 --tries 1
  CMD="   "
  PATH="$W/cmds/bin:$PATH" step cmds calc.auk --hole 2 --tries 1
  CMD="cat > /dev/null; printf '\\377\\376 x'"
  step cmds calc.auk --hole 2 --tries 1
  CMD="sh ./model.sh"
  # a project: holes in two modules, a test in each, numbered root first
  new proj
  mkdir -p "$W/proj/src"
  printf '[package]\nname = "proj"\nversion = "0.1.0"\n' > "$W/proj/raft.toml"
  cat > "$W/proj/src/main.auk" << 'EOF'
fn twice(n: int): int = ??

fn main() {
  print(util.inc(twice(2)))
}

test "twice" { assert twice(3) == 6 }
EOF
  cat > "$W/proj/src/util.auk" << 'EOF'
/// One more than `n`.
pub fn inc(n: int): int {
  ??
}

pub fn dec(n: int): int = n - ??

test "inc" { assert inc(1) == 2 }
EOF
  reply proj 1 'n + n'
  reply proj 2 'n + 1'
  reply proj 3 '1'
  step proj src/main.auk --dry-run
  rm "$W/proj/calls"
  step proj src/main.auk
  # a file that can't be written
  new ro
  reply ro 1 '```auk
n * 2
```'
  chmod 444 "$W/ro/calc.auk"
  step ro calc.auk --hole 2
  chmod 644 "$W/ro/calc.auk"
  if [ "$SLOW" = --slow ]; then
    # an answer that never ends: killed after the test timeout
    new slow
    reply slow 1 '```auk
loop { }
```'
    step slow calc.auk --hole 2 --tries 1
  fi
}

for side in rust auk; do
  LOG="$OUT/$side.log"
  BIN=("${RUST[@]}")
  [ "$side" = auk ] && BIN=("${PORT[@]}")
  : > "$LOG"
  scenario
  cp -R "$W" "$OUT/$side.tree"
done
n=$(grep -c '^== ' "$OUT/rust.log")
if cmp -s "$OUT/rust.log" "$OUT/auk.log" && diff -r "$OUT/rust.tree" "$OUT/auk.tree" > /dev/null; then
  echo "hatch: $n commands, 0 differ"
else
  diff "$OUT/rust.log" "$OUT/auk.log" | head -40 || true
  diff -r "$OUT/rust.tree" "$OUT/auk.tree" | head -20 || true
  echo "hatch: $n commands; outputs or trees differ (diff $OUT/rust.log $OUT/auk.log)"
  exit 1
fi
