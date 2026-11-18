#!/usr/bin/env bash
# Diff the typed programs (`auk dump typed`: signatures, side tables, instances) of the Rust
# compiler and its Auk port over the corpus (see docs/self-host-plan.md, Phase 3), then the core
# modules' tables and instances once (`--core`).
source "$(dirname "$0")/pilot_common.sh"
diff_mode typed
out="$ROOT/target/pilot/typed"
"$AUK" dump typed --core examples/hello.auk > "$out/core.rust" 2>&1 || true
"$PORT" dump typed --core examples/hello.auk > "$out/core.auk" 2>&1 || true
if cmp -s "$out/core.rust" "$out/core.auk"; then
  echo "typed --core: 0 differ"
else
  echo "typed --core: DIFF (diff $out/core.rust $out/core.auk)"
  exit 1
fi
