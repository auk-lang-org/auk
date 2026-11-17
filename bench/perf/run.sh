#!/bin/sh
# Build the Duck and Rust perf suites and time them (best of $RUNS, default 5). Usage: bench/perf/run.sh [bench...]
set -e
here=$(cd "$(dirname "$0")" && pwd); D=${DUCK:-$here/../../target/release/duck}; mkdir -p "$here/out"
for f in "$here"/duck/*.duck; do b=$(basename "$f" .duck)
  "$D" build "$f" -o "$here/out/$b.duck" >/dev/null
  rustc -C opt-level=3 -C target-cpu=native "$here/rust/$b.rs" -o "$here/out/$b.rs"
  rustc -C opt-level=3 -C target-cpu=native -C overflow-checks=on "$here/rust/$b.rs" -o "$here/out/$b.rsoc"
done
python3 -I "$here/time.py" "$@"
