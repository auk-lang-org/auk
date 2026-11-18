#!/usr/bin/env bash
# Which Rust integration tests (tests/*.rs, `#[test]` functions) have an Auk counterpart in the
# test runner (tests/runner/, `suite::name`), per file: ported/total, and the names missing.
# Usage: scripts/test_coverage.sh [--runner <binary>] [--quiet]
#   --runner  the built runner (default target/test-runner; built from tests/runner if missing)
#   --quiet   only the per-file counts and the total
# Exits 1 if any Rust test has no counterpart, or the runner has a test the Rust file doesn't.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RUNNER="$ROOT/target/test-runner"
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --runner) RUNNER="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "usage: scripts/test_coverage.sh [--runner <binary>] [--quiet]" >&2; exit 2 ;;
  esac
done
if [ ! -x "$RUNNER" ]; then
  "$ROOT/target/release/auk" build tests/runner/src/main.auk -o "$RUNNER" || exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Rust: `#[test]`, then (after other attributes) `fn name`
for f in tests/*.rs; do
  n="$(basename "$f" .rs)"
  awk -v s="$n" '
    /^[[:space:]]*#\[test\]/ { want = 1; next }
    want && /^[[:space:]]*#\[/ { next }
    want && match($0, /fn [A-Za-z0-9_]+/) { print s "::" substr($0, RSTART + 3, RLENGTH - 3); want = 0 }
  ' "$f"
done | sort > "$tmp/rust"
"$RUNNER" --list --include-ignored | sort > "$tmp/auk"
total_r=0 total_a=0 bad=0
printf '%-16s %s\n' file ported/total
for f in tests/*.rs; do
  n="$(basename "$f" .rs)"
  r=$(grep -c "^$n::" "$tmp/rust")
  a=$(comm -12 "$tmp/rust" "$tmp/auk" | grep -c "^$n::")
  total_r=$((total_r + r)) total_a=$((total_a + a))
  printf '%-16s %d/%d\n' "$n" "$a" "$r"
  if [ "$QUIET" = 0 ]; then
    comm -23 "$tmp/rust" "$tmp/auk" | grep "^$n::" | sed 's/^/    missing: /'
  fi
done
extra="$(comm -13 "$tmp/rust" "$tmp/auk")"
if [ -n "$extra" ]; then
  echo "in the runner but not in tests/*.rs:"; echo "$extra" | sed 's/^/    /'; bad=1
fi
echo "total: $total_a/$total_r Rust integration tests have an Auk counterpart"
[ "$total_a" = "$total_r" ] && [ "$bad" = 0 ]
