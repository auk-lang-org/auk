#!/usr/bin/env bash
# The ported tools against the Rust ones (docs/self-host-plan.md, Phase 5): `explain` for every
# code, the language server over the corpus (scripts/diff_lsp.py; STEP: every how many columns
# to hover, default 4), the MCP server (scripts/diff_mcp.py), then tests/lsp.rs, tests/mcp.rs
# and tests/explain.rs with the port as $AUK_BIN (tests needing commands the port's driver
# lacks are skipped; tests/auk_bin/mod.rs).
source "$(dirname "$0")/pilot_common.sh"
build_both
out="$ROOT/target/pilot/explain"
rm -rf "$out"
mkdir -p "$out"
n=0 bad=0
for c in "" $(cd docs/errors && ls E*.md | sed 's/\.md$//') E0206 semicolons 400; do
  n=$((n + 1))
  "$AUK" explain $c > "$out/rust" 2>&1 || echo "exit $?" >> "$out/rust"
  "$PORT" explain $c > "$out/auk" 2>&1 || echo "exit $?" >> "$out/auk"
  if ! cmp -s "$out/rust" "$out/auk"; then bad=$((bad + 1)); echo "DIFF explain $c"; fi
done
echo "explain: $n codes, $bad differ"
[ "$bad" -eq 0 ]
# shellcheck disable=SC2046
python3 scripts/diff_lsp.py --step "${STEP:-4}" "$AUK" "$PORT" $(corpus)
python3 scripts/diff_mcp.py "$AUK" "$PORT"
AUK_BIN="$PORT" cargo test --release -q --test lsp --test mcp --test explain
