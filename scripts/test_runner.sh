#!/usr/bin/env bash
# The Auk integration test runner (tests/runner/, the port of tests/*.rs; docs/self-host-plan.md,
# Phase 5) against the Rust `auk` and against the self-hosted port (target/pilot/compiler), then
# the coverage list (scripts/test_coverage.sh: every Rust integration test has a counterpart).
# Usage: scripts/test_runner.sh [--rust|--port] [runner args...]   (e.g. `-j 4 lsp::`)
#   --rust / --port   only that binary (default both)
# Builds the Rust binaries (cargo), the port and the runner first.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
AUK="$ROOT/target/release/auk"
PORT="$ROOT/target/pilot/compiler"
RUNNER="$ROOT/target/test-runner"
which=both
case "${1:-}" in
  --rust) which=rust; shift ;;
  --port) which=port; shift ;;
esac
cargo build --release -q || exit 1
mkdir -p "$ROOT/target/pilot"
[ -d compiler/.raft ] || (cd compiler && "$ROOT/target/release/raft" install >/dev/null) || exit 1
if [ "$which" != rust ]; then "$AUK" build compiler/src/main.auk -o "$PORT" || exit 1; fi
"$AUK" build tests/runner/src/main.auk -o "$RUNNER" || exit 1
fail=0
if [ "$which" != port ]; then
  echo "--- the Rust auk"
  env -u AUK_BIN -u AUK_BIN_LACKS "$RUNNER" "$@" || fail=1
fi
if [ "$which" != rust ]; then
  echo "--- the self-hosted port ($PORT)"
  AUK_BIN="$PORT" "$RUNNER" --no-setup "$@" || fail=1
fi
scripts/test_coverage.sh --quiet --runner "$RUNNER" || fail=1
exit "$fail"
