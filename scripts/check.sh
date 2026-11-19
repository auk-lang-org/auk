#!/usr/bin/env bash
# Everything that must stay green (docs/compiler.md, Testing):
#   1. build      ./build.sh --check: the runtime, raft, and the compiler from the seed `auk`
#                 through stage 3, which must be bit-identical to stage 2 (the fixed point)
#   2. runtime    runtime/test/unit/run.sh: the runtime's unit tests (Auk; AUK_NET_TESTS=1:
#                 with real hosts)
#   3. runner     the integration tests (tests/runner/) against target/bin/auk and raft
#   4. golden     scripts/golden.sh --compare of target/bin/auk with itself: 0 differences
#                 (catches nondeterministic output)
#   5. bench      tests/perf programs on small inputs: `auk build` and `auk run` agree
#   (seed, not by default: ./build.sh --from-seed, the build a fresh clone does, ~1 min)
#   (vscode, not by default: the VS Code extension end to end in a real VS Code,
#    the auk-vscode checkout's scripts/e2e.sh ($AUK_VSCODE, default ../auk-vscode); opens a
#    window, ~30 s)
# Usage: scripts/check.sh [step...]   (steps: build runtime runner golden bench seed vscode;
# default all but seed and vscode)
# Runs every selected step, then lists the failed ones; exits non-zero if any failed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
AUK="$ROOT/target/bin/auk"
STEPS="${*:-build runtime runner golden bench}"

step_build() { ./build.sh --check; }
# real-host TLS tests reach badssl.com, which times out now and then: off unless asked for
step_runtime() { AUK_NET_TESTS="${AUK_NET_TESTS:-0}" sh runtime/test/unit/run.sh; }
step_runner() { scripts/test_runner.sh --no-build; }
step_golden() { scripts/golden.sh --no-build --compare "$AUK"; }
step_seed() { ./build.sh --from-seed; }
step_vscode() { "${AUK_VSCODE:-$ROOT/../auk-vscode}/scripts/e2e.sh" "$AUK"; }

# fib 25, sieve 100k, ...: every bench program built and JIT-run on a small input, same output.
step_bench() {
  local out; out="$(mktemp -d)"
  local fail=0 b n
  for spec in fib:25 sieve:100000 nbody:1000 hashmap:10000 trees:10 strings:10000 sort:10000; do
    b="${spec%%:*}" n="${spec#*:}"
    if ! "$AUK" build "tests/perf/auk/$b.auk" -o "$out/$b" > "$out/$b.log" 2>&1; then
      echo "bench $b: build failed"; cat "$out/$b.log"; fail=1; continue
    fi
    "$out/$b" "$n" > "$out/$b.built" 2>&1 || { echo "bench $b: exit $?"; fail=1; }
    "$AUK" run "tests/perf/auk/$b.auk" "$n" > "$out/$b.jit" 2>&1 || { echo "bench $b: auk run exit $?"; fail=1; }
    if cmp -s "$out/$b.built" "$out/$b.jit" && [ -s "$out/$b.built" ]; then
      echo "bench $b $n: ok ($(head -c 60 "$out/$b.built" | head -1))"
    else
      echo "bench $b: built and JIT output differ or are empty"; fail=1
    fi
  done
  rm -rf "$out"
  return "$fail"
}

failed=""
for s in $STEPS; do
  if ! declare -F "step_$s" >/dev/null; then echo "check.sh: unknown step $s" >&2; exit 2; fi
  echo "=== $s"
  start=$SECONDS
  if "step_$s"; then echo "=== $s: ok ($((SECONDS - start))s)"
  else echo "=== $s: FAILED ($((SECONDS - start))s)"; failed="$failed $s"
    # every later step runs target/bin/auk
    [ "$s" = build ] && { echo "check.sh: the build failed; stopping"; exit 1; }
  fi
done
if [ -n "$failed" ]; then echo "check.sh: failed:$failed"; exit 1; fi
echo "check.sh: all ok"
