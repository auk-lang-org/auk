#!/bin/sh
# Build the Auk and Rust perf suites and time them (best of $RUNS, default 5). Usage: tests/perf/run.sh [bench...]
set -e
here=$(cd "$(dirname "$0")" && pwd); D=${AUK:-$here/../../target/bin/auk}; mkdir -p "$here/out"
for f in "$here"/auk/*.auk; do b=$(basename "$f" .auk)
  "$D" build "$f" -o "$here/out/$b.auk" >/dev/null
  rustc -C opt-level=3 -C target-cpu=native "$here/rust/$b.rs" -o "$here/out/$b.rs"
  rustc -C opt-level=3 -C target-cpu=native -C overflow-checks=on "$here/rust/$b.rs" -o "$here/out/$b.rsoc"
done
python3 -I "$here/time.py" "$@"
