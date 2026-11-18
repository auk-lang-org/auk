#!/usr/bin/env bash
# Diff `auk run --live` (Rust, src/live.rs) and its Auk port (compiler/src/live.auk; see
# docs/self-host-plan.md, Phase 5): run the same scripted edit sequences with each, in the same
# scratch directory one after the other, and compare each scenario's stdout, stderr and exit
# code.
#
# Live reload is about timing, so the programs here print only when told to: each polls a file
# `step` and prints a line when its text changes. The script edits a source (written to a
# temporary file and renamed into place, so the watcher never sees half a file), waits for the
# watcher's note (`[live] reloaded in N ms`, `not reloaded`, ...), then changes `step` and waits
# for the program's line. So the output is the same from run to run, except the reload time,
# which is masked. Scenarios: a code swap keeping state, a type error keeping the old code, a
# signature change (old frames keep calling the old function), a layout `main` holds
# (restart); a project with a dependency (`sup`): a layout only a supervised task holds (just
# that task restarts), a touched dependency file, a layout `main` holds; a module file deleted
# and renamed, the root file renamed; a program that exits, panics or is killed while watched;
# a missing file and a type error at the start; usage errors.
#
# Usage: scripts/diff_live.sh [--no-build]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ "${1:-}" != "--no-build" ]; then
  cargo build --release -q
  mkdir -p "$ROOT/target/pilot"
  "$ROOT/target/release/auk" build compiler/src/main.auk -o "$ROOT/target/pilot/compiler"
fi
OUT="$ROOT/target/pilot/live-diff"
rm -rf "$OUT"
mkdir -p "$OUT"
W="$OUT/work" # the scenarios' directory, the same path for both binaries

# start <dir> <args...>: `auk run --live <args...>` in the background in <dir>.
start() {
  CUR="$1"
  shift
  (cd "$W/$CUR" && exec "$BIN" run --live "$@") > "$OUT/$CUR.out" 2> "$OUT/$CUR.err" &
  P=$!
}

# waitfor <n> <regex>: wait until <n> lines of the program's stderr match <regex> (whole line);
# after 30 s note the timeout in the log and go on.
waitfor() {
  local n="$1" re="$2" t=0
  while [ "$(grep -c -x -E -- "$re" "$OUT/$CUR.err" || true)" -lt "$n" ]; do
    sleep 0.05
    t=$((t + 1))
    if [ $t -gt 600 ]; then
      echo "!! timed out waiting for $n x $re" >> "$LOG/$CUR"
      return 0
    fi
  done
}

# put <file>: stdin becomes <file> in the current scenario (renamed into place).
put() {
  cat > "$W/$CUR/.put.tmp"
  mv "$W/$CUR/.put.tmp" "$W/$CUR/$1"
}

# step <text>: the programs' trigger.
step() {
  printf '%s' "$1" > "$W/$CUR/.step.tmp"
  mv "$W/$CUR/.step.tmp" "$W/$CUR/step"
}

# stop: kill the driver, wait for it and its child, and log the scenario.
stop() {
  local rc=0
  kill "$P" 2> /dev/null || true
  wait "$P" 2> /dev/null || rc=$?
  # the child notices its parent is gone within its 200 ms poll
  sleep 0.5
  {
    echo "== $CUR"
    cat "$OUT/$CUR.out"
    echo "-- stderr"
    sed -E 's/reloaded in [0-9]+ ms/reloaded in _ ms/' "$OUT/$CUR.err"
    echo "-- exit $rc"
  } >> "$LOG/$CUR"
}

R='\[live\] reloaded in [0-9]+ ms'

scenario() {
  rm -rf "$W"
  mkdir -p "$W"
  rm -rf "$LOG"
  mkdir -p "$LOG"

  # usage errors (no file)
  mkdir -p "$W/usage"
  CUR=usage
  rc=0
  (cd "$W/usage" && "$BIN" run --live) > "$OUT/usage.out" 2> "$OUT/usage.err" || rc=$?
  { echo "== usage"; cat "$OUT/usage.out"; echo "-- stderr"; cat "$OUT/usage.err"; echo "-- exit $rc"; } >> "$LOG/usage"

  # a code swap keeping state, a type error, a signature change, a layout main holds
  mkdir -p "$W/swap"
  CUR=swap
  step 0
  body() {
    cat << EOF
struct S { n: int$1 }

fn msg($2): str = $3

fn main() uses fs, time {
  var s = S { n: 0$4 }
  var seen = ""
  while true {
    let st = fs.read("step") else ""
    if st != seen {
      seen = st
      s.n += 1
      eprint(msg($5))
    }
    time.sleep(10)
  }
}
EOF
  }
  body "" "n: int" '"a{n}"' "" "s.n" | put live.auk
  start swap live.auk
  waitfor 1 a1
  body "" "n: int" '"b{n}"' "" "s.n" | put live.auk
  waitfor 1 "$R"
  step 1
  waitfor 1 b2
  body "" "n: int" '5' "" "s.n" | put live.auk
  waitfor 1 '\[live\] not reloaded: .*'
  step 2
  waitfor 1 b3
  body "" "n: int" '"c{n}"' "" "s.n" | put live.auk
  waitfor 2 "$R"
  step 3
  waitfor 1 c4
  # a new parameter: main's running frame keeps calling the old `msg`
  body "" "n: int, k: int" '"d{n}"' "" "s.n, 0" | put live.auk
  waitfor 3 "$R"
  step 4
  waitfor 1 c5
  # a new field: main holds an S
  body ", k: int" "n: int, k: int" '"e{n} {k}"' ", k: 7" "s.n, s.k" | put live.auk
  waitfor 1 '.*restarting the program'
  waitfor 1 'e1 7'
  step 5
  waitfor 1 'e2 7'
  stop

  # a project with a dependency: a layout only the supervised task holds, then one main holds
  mkdir -p "$W/dep/src"
  CUR=dep
  step 0
  printf '[package]\nname = "app"\nversion = "0.1.0"\neffects = ["fs", "time"]\n\n[deps]\nsup = "^0.1"\n' > "$W/dep/raft.toml"
  (cd "$W/dep" && RAFT_REGISTRY="$ROOT/packages" "$ROOT/target/release/raft" install > /dev/null)
  app() {
    cat << EOF
struct Counter { $1 }
struct Main { $4 }

fn count(): ()! uses fs, time {
  var c = Counter { $2 }
  var seen = ""
  while true {
    let st = fs.read("step") else ""
    if st != seen {
      seen = st
      c.n += $3
      eprint("count {c.n}")
    }
    time.sleep(10)
  }
}

fn main(): int! uses fs, time {
  let m = Main { $5 }
  eprint("main {m.a}")
  sup.run([sup.child("count", () => count())], sup.one_for_one(5, 60_000))?
  0
}
EOF
  }
  app "n: int" "n: 0" 1 "a: int" "a: 1" | put src/main.auk
  start dep src/main.auk
  waitfor 1 'count 1'
  step 1
  waitfor 1 'count 2'
  app "n: int, k: int" "n: 0, k: 1" 100 "a: int" "a: 1" | put src/main.auk
  waitfor 1 '\[live\] `Counter` changed shape: stopped 1 task\(s\) that use it'
  waitfor 1 'count 100'
  step 2
  waitfor 1 'count 200'
  # a dependency's file changed (touched): a reload, nothing else
  touch "$W/dep/.raft/sup/src/lib.auk"
  waitfor 2 "$R"
  step 3
  waitfor 1 'count 300'
  app "n: int, k: int" "n: 0, k: 1" 100 "a: int, b: int" "a: 1, b: 2" | put src/main.auk
  waitfor 1 '.*`Main` changed shape and `main`.s side of the program uses it: restarting the program'
  waitfor 2 'main 1'
  waitfor 2 'count 100'
  stop

  # files deleted and renamed
  mkdir -p "$W/files/src"
  CUR=files
  step 0
  printf '[package]\nname = "files"\nversion = "0.1.0"\neffects = ["fs", "time"]\n' > "$W/files/raft.toml"
  printf 'pub fn msg(n: int): str = "u{n}"\n' | put src/util.auk
  main_of() {
    cat << EOF
fn main() uses fs, time {
  var n = 0
  var seen = ""
  while true {
    let st = fs.read("step") else ""
    if st != seen {
      seen = st
      n += 1
      eprint($1)
    }
    time.sleep(10)
  }
}
EOF
  }
  main_of 'util.msg(n)' | put src/main.auk
  start files src/main.auk
  waitfor 1 u1
  mv "$W/files/src/util.auk" "$W/files/src/util.bak"
  waitfor 1 '\[live\] not reloaded: .*'
  step 1
  waitfor 1 u2
  mv "$W/files/src/util.bak" "$W/files/src/util.auk"
  waitfor 1 "$R"
  step 2
  waitfor 1 u3
  # the root file renamed away and back
  mv "$W/files/src/main.auk" "$W/files/src/main2.auk"
  waitfor 2 '\[live\] not reloaded: .*'
  mv "$W/files/src/main2.auk" "$W/files/src/main.auk"
  waitfor 2 "$R"
  step 3
  waitfor 1 u4
  # a module deleted while still used, then no longer used
  rm "$W/files/src/util.auk"
  waitfor 3 '\[live\] not reloaded: .*'
  main_of '"m{n}"' | put src/main.auk
  waitfor 3 "$R"
  # main's running loop is its old body: it still calls (the old) util.msg
  step 4
  waitfor 1 u5
  stop

  # the program exits, panics, is killed, while watched; arguments
  mkdir -p "$W/exit/src"
  CUR=exit
  step 0
  printf '[package]\nname = "ex"\nversion = "0.1.0"\neffects = ["fs", "env", "time", "ffi"]\n' > "$W/exit/raft.toml"
  ex() {
    cat << EOF
extern fn c_raise(sig: int): int = "int raise(int)"

fn main(): int uses fs, env, time, ffi {
  eprint("args {env.args()}")
  var seen = ""
  while true {
    let st = fs.read("step") else ""
    if st != seen {
      seen = st
      eprint("$1 {st}")
      if st == "stop" {
        print("bye")
        return 3
      }
      if st == "panic" {
        let xs: [int] = []
        eprint("{xs[1]}")
      }
      if st == "kill" { let _ = c_raise(9) }
    }
    time.sleep(10)
  }
  0
}
EOF
  }
  ex step | put src/main.auk
  start exit src/main.auk one "two words"
  waitfor 1 'step 0'
  step stop
  waitfor 1 '\[live\] the program exited with 3; waiting for a change to start it again'
  step 1
  ex step: | put src/main.auk
  waitfor 1 'step: 1'
  step panic
  waitfor 2 '\[live\] the program (exited with [0-9]+|was killed); waiting for a change to start it again'
  step 2
  ex 'step>' | put src/main.auk
  waitfor 1 'step> 2'
  step kill
  waitfor 3 '\[live\] the program (exited with [0-9]+|was killed); waiting for a change to start it again'
  step 3
  ex 'step!' | put src/main.auk
  waitfor 1 'step! 3'
  stop

  # a missing file, then one with a type error, then a fixed one
  mkdir -p "$W/fix"
  CUR=fix
  step 0
  start fix fix.auk
  waitfor 1 '\[live\] waiting for a fix'
  printf 'fn main() { let x: int = "no"\n  eprint("x {x}") }\n' | put fix.auk
  waitfor 2 '\[live\] waiting for a fix'
  printf 'fn main() { eprint("fixed") }\n' | put fix.auk
  waitfor 1 fixed
  waitfor 1 '\[live\] the program exited with 0; waiting for a change to start it again'
  stop
}

LOG="$OUT/rust"
BIN="$ROOT/target/release/auk"
scenario
LOG="$OUT/port"
BIN="$ROOT/target/pilot/compiler"
scenario

total=0
differ=0
for f in "$OUT"/rust/*; do
  total=$((total + 1))
  g="$OUT/port/${f##*/}"
  if ! cmp -s "$f" "$g"; then
    differ=$((differ + 1))
    echo "differs: ${f##*/}"
    diff "$f" "$g" | head -20 || true
  fi
done
grep -h '^!! timed out' "$OUT"/rust/* "$OUT"/port/* || true
echo "live: $total scenarios, $differ differ (outputs: $OUT/rust, $OUT/port)"
[ "$differ" -eq 0 ]
