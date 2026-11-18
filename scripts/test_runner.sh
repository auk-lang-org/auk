#!/usr/bin/env bash
# The integration tests (tests/runner/, an Auk project; it spawns the binaries and compares their
# output) against target/bin/auk and target/bin/raft, or the binaries in $AUK_BIN / $RAFT_BIN.
#
#   scripts/test_runner.sh [--no-build] [runner args...]   (e.g. `-j 4 lsp::`, `--list`)
#
# Builds them first (./build.sh) unless --no-build, then the runner itself.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ "${1:-}" = --no-build ]; then shift; else ./build.sh > /dev/null || exit 1; fi
AUK="${AUK_BIN:-$ROOT/target/bin/auk}"
RAFT="${RAFT_BIN:-$ROOT/target/bin/raft}"
RUNNER="$ROOT/target/test-runner"
"$AUK" build tests/runner/src/main.auk -o "$RUNNER" || exit 1
AUK_BIN="$AUK" RAFT_BIN="$RAFT" "$RUNNER" "$@"
