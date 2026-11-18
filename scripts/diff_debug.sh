#!/usr/bin/env bash
# Diff `auk debug` and `auk dap` (Rust) and their Auk port (`compiler debug`/`compiler dap`,
# compiler/src/debug.auk, dap.auk, dbg_eval.auk; see docs/self-host-plan.md, Phase 5): every
# `auk debug` command below runs with each binary in compiler/tests/debug/ (batch reports as
# text and --json, usage errors, breakpoints by file:line and function, conditions, --print,
# --eval with expressions evaluated at the stops, panics, tasks, --timeout, programs that don't
# compile, and the interactive prompt with scripted input), comparing stdout, stderr and exit
# code; then scripts/diff_dap.py plays the same DAP sessions to both servers.
#
# Normalized, because it is inherently nondeterministic: where a `--timeout` stops an endless
# loop (its line and the loop counter's value); in DAP sessions, where the program's `output`
# events fall among the engine's (see diff_dap.py). Nothing else. Not covered: Ctrl-C at the
# prompt (needs a terminal), and EOF at the prompt before `run` (both binaries wait forever for
# a program that was never started), `quit` typed ahead while the program runs (it races the
# program to its output: Rust differs from itself).
#
# Usage: scripts/diff_debug.sh [--no-build] [--no-dap]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ " $* " != *" --no-build "* ]]; then
  cargo build --release -q
  mkdir -p "$ROOT/target/pilot"
  "$ROOT/target/release/auk" build compiler/src/main.auk -o "$ROOT/target/pilot/compiler"
fi
RUST="$ROOT/target/release/auk"
PORT="$ROOT/target/pilot/compiler"
OUT="$ROOT/target/pilot/debug-diff"
rm -rf "$OUT"
mkdir -p "$OUT"
D="$ROOT/compiler/tests/debug"
unset AUK_LEAK_CHECK AUK_TRACE AUK_DEBUG

# one <bin> <stdin file> <args...>: `debug <args>` in $D, its output and exit code.
one() {
  local bin="$1" input="$2" rc=0
  shift 2
  (cd "$D" && "$bin" debug "$@" < "$input") > "$OUT/stdout" 2> "$OUT/stderr" || rc=$?
  echo "-- stdout"
  cat "$OUT/stdout"
  echo "-- stderr"
  cat "$OUT/stderr"
  echo "-- exit $rc"
}

# where a --timeout stopped spin.auk's endless loop: any line of the loop, any count
norm() {
  sed -E -e 's/spin\.auk:[0-9]+/spin.auk:L/g' -e 's/"line":[0-9]+/"line":L/g' \
    -e 's/(  n = |"n":")[0-9]+/\1N/g'
}

n=0
bad=0
# case <stdin file> <args...>
case_() {
  local input="$1"
  shift
  n=$((n + 1))
  one "$RUST" "$input" "$@" > "$OUT/rust.$n"
  one "$PORT" "$input" "$@" > "$OUT/port.$n"
  case "$*" in
    *spin.auk*)
      norm < "$OUT/rust.$n" > "$OUT/r" && mv "$OUT/r" "$OUT/rust.$n"
      norm < "$OUT/port.$n" > "$OUT/p" && mv "$OUT/p" "$OUT/port.$n"
      ;;
  esac
  if ! cmp -s "$OUT/rust.$n" "$OUT/port.$n"; then
    bad=$((bad + 1))
    echo "DIFF $n: debug $*"
    diff "$OUT/rust.$n" "$OUT/port.$n" | head -20 || true
  fi
}
NUL=/dev/null
c() { case_ "$NUL" "$@"; }
# repl <input text> <args...>: the interactive prompt with typed-ahead input
repl() {
  printf '%b' "$1" > "$OUT/input.$((n + 1))"
  local f="$OUT/input.$((n + 1))"
  shift
  case_ "$f" --repl "$@"
}

# usage errors
c
c --nope points.auk
c -b
c points.auk --nope
c --catch maybe points.auk
c --max-stops x points.auk
c --max-stops -1 points.auk
c --timeout 0 points.auk
c --timeout abc points.auk
c --print
c missing.auk
c ../debug
# batch: no breakpoints, file:line and functions, --print, --max-stops
c points.auk
c --batch points.auk
c --json points.auk
c -b points.auk:5 -b fact -p n,nx --max-stops 3 points.auk
c --json -b points.auk:5 -b fact -p n,nx --max-stops 3 points.auk
c -b points.auk:4 -b points.auk:19 points.auk
c --json -b prog.add -b points.add -b points.auk:1 points.auk
c -b nope -b points.auk:999 -b points.auk:4 points.auk
c --json -b nope points.auk
c --max-stops 0 -b points.auk:5 points.auk
c -b fact -p "n, ,x" points.auk
c -p total -b points.auk:24 points.auk
# expressions: --print items and --eval, conditions
c -b "eval.auk:16 if i % 2 == 1" -p "total,pts[1].x" -e "dist2(pts[0]) + i" eval.auk
c --json -b "eval.auk:16 if i % 2 == 1" -p "total,pts[1].x" -e "dist2(pts[0]) + i" eval.auk
c --json -b "fact if n == 2" -e "n * 10" -e nope -e "1 +" -e "fact(n + 1)" -e pts eval.auk
c -b "fact if n <" --max-stops 2 eval.auk
c --json -b "fact if nope > 1" --max-stops 1 eval.auk
c -b eval.auk:16 -e "total = total + 100" --max-stops 2 eval.auk
c -b eval.auk:16 -p i -e "pts[7]" -e "pts.map(p => p.x * i)" -e "\"{i}!\"" --max-stops 1 eval.auk
c -b eval.auk:3 -e "p.x + p.y" -e "dist2(Point { x: p.y, y: p.x })" eval.auk
c -b eval.auk:18 -e "fact(total)" -e "{ let t = total * 2\n t }" eval.auk
c -b "dist2 if p.x > 1" -p p eval.auk
c -b pick -e "xs.len() + i" -e n generic.auk
c --json -b generic.auk:3 -e "xs[0]" -e "i * 2" generic.auk
c -b generic.auk:12 -e "twice(v => v + 1, k)" -e "pick(names, 1)" generic.auk
# panics, tasks, catch
c panic.auk
c --json panic.auk
c --catch none panic.auk
c --catch all panic.auk
c tasks.auk
c --catch all tasks.auk
c --json --catch all -b tasks.auk:4 tasks.auk
c -b work -e "k * 2" tasks.auk
c --catch uncaught -b boom -p xs tasks.auk
c index.auk
# the program's arguments
c -b greet -p who args.auk a b
c --json args.auk "x y" z
# --timeout: an endless loop (normalized), a call that doesn't return in time
c --timeout 0.5 spin.auk
c --json --timeout 0.5 spin.auk
c --json --timeout 0.5 sleepy.auk
c --timeout 0.25 -b fact -p n points.auk
# programs that don't compile
c bad.auk
c --json bad.auk
c -b main --repl bad.auk
# the interactive prompt
repl 'b add\nr\nn\n\np nx\nup\nbt\nfinish\np total\nnope\nd\nc\n' points.auk
repl 'b 16 if i == 2\nr\np i * 100\np total = 1000\np total\nd\nc\n' eval.auk
repl 'help\nbt\nlist\nb\nb points.auk:10\nrun\nrun\nlist\nframe 1\ndown\ndown\nframe 9\nframe x\nup\nup\nthreads\nthread 1\nthread 5\nthread\nthread x\np\np n\np zz\np n zz\nlocals\ninfo locals\ncatch all\ns\ns\nf\nwhere\nbacktrace\nb\nq\n' points.auk
repl 'r\nbt\np\np k * 2\nc\n' panic.auk
repl 'catch all\nb tasks.auk:4\nr\nthreads\np\nc\nthreads\nthread 2\nbt\nd\nc\n' tasks.auk
repl 'b fact\nr\n' points.auk
repl 'p\nn\nd 7\nb 99\nb nope\nb 12 if\nb 16 if i ==\nb 16 if i > 1\nc\np i\ncatch\nd 1\nc\n' eval.auk
repl 'b greet\nr\np who\np who.len() * 2\nc\nc\n' args.auk p q
repl '\n\nr\n' points.auk
repl 'b pick\nr\np\np n\nn\np n\np xs.len()\nkill\n' generic.auk
echo "debug: $n commands, $bad differ"

dap=0
if [[ " $* " != *" --no-dap "* ]]; then
  python3 scripts/diff_dap.py "$RUST" "$PORT" || dap=1
fi
[ "$bad" -eq 0 ] && [ "$dap" -eq 0 ]
