#!/usr/bin/env bash
# Everything that must stay green (docs/compiler.md, Testing; the self-host plan's Phase 0 gate):
#   1. cargo test --release        the compiler's unit and integration tests (tests/*.rs)
#   2. runtime/c/test/run.sh       the C runtime's unit tests (AUK_NET_TESTS=1: with real hosts)
#   3. pilot diffs                 tokens, AST, module tree, `auk check` (--json and text),
#                                  `auk holes`, the typed program, formatting and MIR of the Auk
#                                  port (compiler/) = the Rust ones; raft (raft/) = the Rust raft
#   4. golden self-consistency     scripts/golden.sh --compare with the Rust auk itself: 0 diffs
#                                  (catches nondeterministic output)
#   5. bench smoke                 bench/perf programs, small inputs, `auk build` = `auk run`
#   (backend, not by default: the self-hosted back end's checks, scripts/diff_mir.sh and
#    run_backend.sh, ~8 min; scripts/diff_llvm.sh, ~15 min, is separate)
# Usage: scripts/check.sh [step...]   (steps: cargo runtime pilot golden bench backend; default
# all but backend)
# Runs every selected step, then lists the failed ones; exits non-zero if any failed.
# Needs the packages' .raft/ dependencies installed (`raft install`), like the suite.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
AUK="$ROOT/target/release/auk"
STEPS="${*:-cargo runtime pilot golden bench}"

step_cargo() { cargo test --release --no-fail-fast; }
# real-host TLS tests reach badssl.com, which times out now and then: off unless asked for
step_runtime() { AUK_NET_TESTS="${AUK_NET_TESTS:-0}" sh runtime/c/test/run.sh; }
step_pilot() { scripts/gen_error_pages.sh --check && scripts/diff_tokens.sh && scripts/diff_ast.sh && scripts/diff_resolve.sh && scripts/diff_check.sh && scripts/diff_check_text.sh && scripts/diff_holes.sh && scripts/diff_typed.sh && scripts/diff_fmt.sh && scripts/diff_ir.sh && scripts/diff_raft.sh; }
step_backend() { scripts/diff_mir.sh && scripts/run_backend.sh; }
step_golden() { scripts/golden.sh --no-build --compare "$AUK"; }

# fib 25, sieve 100k, ...: every bench program built and JIT-run on a small input, same output.
step_bench() {
  local out; out="$(mktemp -d)"
  local fail=0 b n
  for spec in fib:25 sieve:100000 nbody:1000 hashmap:10000 trees:10 strings:10000 sort:10000; do
    b="${spec%%:*}" n="${spec#*:}"
    if ! "$AUK" build "bench/perf/auk/$b.auk" -o "$out/$b" > "$out/$b.log" 2>&1; then
      echo "bench $b: build failed"; cat "$out/$b.log"; fail=1; continue
    fi
    "$out/$b" "$n" > "$out/$b.built" 2>&1 || { echo "bench $b: exit $?"; fail=1; }
    "$AUK" run "bench/perf/auk/$b.auk" "$n" > "$out/$b.jit" 2>&1 || { echo "bench $b: auk run exit $?"; fail=1; }
    if cmp -s "$out/$b.built" "$out/$b.jit" && [ -s "$out/$b.built" ]; then
      echo "bench $b $n: ok ($(head -c 60 "$out/$b.built" | head -1))"
    else
      echo "bench $b: built and JIT output differ or are empty"; fail=1
    fi
  done
  rm -rf "$out"
  return "$fail"
}

cargo build --release -q || exit 1
failed=""
for s in $STEPS; do
  if ! declare -F "step_$s" >/dev/null; then echo "check.sh: unknown step $s" >&2; exit 2; fi
  echo "=== $s"
  start=$SECONDS
  if "step_$s"; then echo "=== $s: ok ($((SECONDS - start))s)"
  else echo "=== $s: FAILED ($((SECONDS - start))s)"; failed="$failed $s"; fi
done
if [ -n "$failed" ]; then echo "check.sh: failed:$failed"; exit 1; fi
echo "check.sh: all ok"
