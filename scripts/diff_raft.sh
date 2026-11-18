#!/usr/bin/env bash
# Diff the Rust `raft` and its Auk port (raft/, see docs/self-host-plan.md, Phase 5): run the same
# scenario of raft commands with each, in the same scratch directory one after the other, and
# compare every command's stdout, stderr and exit code, and after every command the whole tree
# (each file's path and SHA-256: raft.toml, raft.lock, .raft/). Then run tests/raft.rs against
# the port (RAFT_BIN).
#
# Usage: scripts/diff_raft.sh [--no-tests]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
cargo build --release -q
mkdir -p "$ROOT/target/pilot"
"$ROOT/target/release/auk" build raft/src/main.auk -o "$ROOT/target/pilot/raft"
RUST="$ROOT/target/release/raft"
PORT="$ROOT/target/pilot/raft"
OUT="$ROOT/target/pilot/raft-diff"
REG="$ROOT/tests/fixtures/registry"
rm -rf "$OUT"
mkdir -p "$OUT"
W="$OUT/work" # the scenario's directory, the same path for both binaries

# step <dir> <args...>: one raft command in <dir>, its output and the tree after it, into $LOG.
step() {
  local dir="$1" rc=0
  shift
  (cd "$W/$dir" && "$BIN" "$@") > "$OUT/stdout" 2> "$OUT/stderr" || rc=$?
  {
    echo "== ($dir) raft $*"
    cat "$OUT/stdout"
    echo "-- stderr"
    cat "$OUT/stderr"
    echo "-- exit $rc"
    (cd "$W" && find . -type f | LC_ALL=C sort | while read -r f; do echo "$(shasum -a 256 < "$f" | cut -c1-16) $f"; done)
  } >> "$LOG"
}

# The scenario: every command and every error raft reports, on the fixture registry and on the
# repository's packages/.
scenario() {
  rm -rf "$W"
  mkdir -p "$W"
  export RAFT_REGISTRY="$REG"
  step . help
  step . --help
  step . -h
  step .
  step . frobnicate
  step . new
  step . add
  step . install
  step . list
  step . new app
  step . new geo --lib
  step . new --lib geo2
  step . new app
  step . new Bad-Name
  step . new net
  step . new 9lives
  step app add app
  step app add Bad
  step app add nope
  step app add lost
  step app add a
  step app add a
  step app list
  step app/src list
  step app add fetch
  sed -i.bak 's/effects = \[\]/effects = ["fs"]/' "$W/app/raft.toml" && rm "$W/app/raft.toml.bak"
  step app add fetch
  sed -i.bak 's/effects = \["fs"\]/effects = ["net", "fs"]/' "$W/app/raft.toml" && rm "$W/app/raft.toml.bak"
  step app add fetch
  step app add bad
  step app list
  echo 'c = "^1.0"  # old' >> "$W/app/raft.toml"
  step app install
  step app add c
  step app add old
  step app remove zzz
  step app remove fetch
  mkdir -p "$W/app/.raft/stale/src" "$W/app/.raft/.hidden"
  echo x > "$W/app/.raft/loose"
  ln -s "$W/geo" "$W/app/.raft/linked" # removed as a link: geo/ itself stays
  step app install
  echo 'pub fn evil() {}' > "$W/app/.raft/b/src/lib.auk"
  step app install
  rm -rf "$W/app/.raft/b"
  step app install
  sed -i.bak 's/^checksum = "sha256:\(.\)/checksum = "sha256:0\1/' "$W/app/raft.lock" && rm "$W/app/raft.lock.bak"
  step app install
  rm "$W/app/raft.lock"
  step app install
  # path dependencies
  echo 'b = "^1.0"' >> "$W/geo/raft.toml"
  step app add geo --path ../geo
  step app add --path ../geo geo2
  step app add nowhere --path ../nowhere
  echo 'pub fn x(): int { 1 }' > "$W/geo/src/lib.auk"
  step app install
  step app list
  step . new geo3 --lib
  echo 'app = { path = "../app" }' >> "$W/geo3/raft.toml"
  step app add geo3 --path ../geo3
  step . new two --lib
  echo 'a = { path = "../geo" }' >> "$W/two/raft.toml"
  step app add two --path ../two
  step app remove geo
  step app remove a
  step app remove c
  step app list
  # bad manifests and locks
  step . new m
  cp "$W/m/raft.toml" "$W/m.toml"
  printf '[package]\nname = "m"\nversion = "1.0"\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\neffects = ["gpu"]\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[link]\nlibs = ["z"]\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\neffects = ["ffi"]\n[link]\nlibs = ["a b"]\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\neffects = ["ffi"]\n[link]\nwindows = []\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[deps]\nb = ">1"\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[deps]\nb = { git = "x" }\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[deps]\nb = ["x"]\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = 1\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[package]\n' > "$W/m/raft.toml"
  step m install
  printf 'name = "m"\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m\\u00e9"\nversion = "0.1.0"\n' > "$W/m/raft.toml"
  step m install
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[deps]\n"b" = "~1.0"  # keep\nc = "*"\n\n[extra]\n' > "$W/m/raft.toml"
  step m install
  step m add a
  step m add b
  step m remove b
  step m remove c
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[deps]\nb = "*"\n' > "$W/m/raft.toml"
  step m install
  step m list
  printf '[package]\nname = "m"\nversion = "0.1.0"\n[deps]\nb = "=1.0.3"\n' > "$W/m/raft.toml"
  step m install
  cp "$W/m.toml" "$W/m/raft.toml"
  step m add b
  printf '[[package]]\nname = "b"\n' > "$W/m/raft.lock"
  step m install
  printf 'garbage' > "$W/m/raft.lock"
  step m install
  # the repository's packages, from the default registry
  unset RAFT_REGISTRY
  step . new real
  step real add http
  sed -i.bak 's/effects = \[\]/effects = ["net", "fs", "time", "env", "rand", "gui", "ffi"]/' "$W/real/raft.toml" && rm "$W/real/raft.toml.bak"
  step real add http
  step real add splash
  step real add nosuch
  step real list
  step real add log
  step real add term
  step real remove http
  step real list
  step real install
  # a real project, with its committed raft.lock (stale if a package changed since) and then a new one
  mkdir "$W/live"
  cp -R "$ROOT/examples/live-site/raft.toml" "$ROOT/examples/live-site/raft.lock" "$ROOT/examples/live-site/src" "$W/live/"
  step live install
  rm "$W/live/raft.lock"
  step live install
  step live list
  rm -rf "$W/live/.raft/http"
  step live install
}

for side in rust auk; do
  LOG="$OUT/$side.log"
  BIN="$RUST"
  [ "$side" = auk ] && BIN="$PORT"
  : > "$LOG"
  scenario
  cp -R "$W" "$OUT/$side.tree"
done
n=$(grep -c '^== ' "$OUT/rust.log")
if cmp -s "$OUT/rust.log" "$OUT/auk.log" && diff -r "$OUT/rust.tree" "$OUT/auk.tree" > /dev/null; then
  echo "raft: $n commands, 0 differ"
else
  diff "$OUT/rust.log" "$OUT/auk.log" | head -40 || true
  diff -r "$OUT/rust.tree" "$OUT/auk.tree" | head -10 || true
  echo "raft: $n commands; outputs or trees differ (diff $OUT/rust.log $OUT/auk.log)"
  exit 1
fi
if [ "${1:-}" != --no-tests ]; then
  RAFT_BIN="$PORT" cargo test --release -q --test raft
fi
