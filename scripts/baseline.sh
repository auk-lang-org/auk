#!/usr/bin/env bash
# The perf baseline (docs/self-host-plan.md, Phase 0): bench/perf numbers and compile times of
# the current build, written to docs/perf-baseline.md (or $1) with the machine, date and commit.
# Every later phase compares against it. Run it on a quiet machine.
#   scripts/baseline.sh [out.md]        RUNS=n (default 5): best of n for every number
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="${1:-docs/perf-baseline.md}"
RUNS="${RUNS:-5}"
AUK="$ROOT/target/bin/auk"
./build.sh > /dev/null
export LC_ALL=C
load="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}' || cut -d' ' -f1 /proc/loadavg)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
# copies outside any project (examples/ is a project: its programs load and compile every
# dependency, which dominates their times; one row measures that)
cp examples/hello.auk examples/tour.auk examples/life.auk "$SCRATCH/"

echo "baseline: bench/perf (RUNS=$RUNS)..." >&2
BENCH="$(RUNS="$RUNS" AUK="$AUK" sh bench/perf/run.sh)"

echo "baseline: compile times..." >&2
find tests examples packages compiler -name '*.auk' -not -path '*/.raft/*' \
  | LC_ALL=C sort > "$SCRATCH/corpus"
COMPILE="$(python3 -I - "$AUK" "$RUNS" "$SCRATCH" <<'EOF'
import subprocess, sys, time, os
auk, runs, scratch = sys.argv[1], int(sys.argv[2]), sys.argv[3]
corpus = open(os.path.join(scratch, "corpus")).read().split()

def best(cmds, n=runs, stdin=None):
    """Best wall time over n repetitions of running every command in cmds in sequence."""
    b = 1e9
    for _ in range(n):
        t = time.perf_counter()
        for c in cmds:
            subprocess.run(c, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        b = min(b, time.perf_counter() - t)
    return b

def ok(c):
    return subprocess.run(c, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def has_main(f):
    return any(l.startswith(("fn main(", "pub fn main(")) for l in open(f))

total = sum(os.path.getsize(f) for f in corpus)
mains = [f for f in corpus if has_main(f) and ok([auk, "check", f])]
rows = []
def row(what, secs, note=""):
    rows.append(f"| {what} | {secs * 1000:,.0f} ms | {note} |")

row(f"`auk check` of every corpus file ({len(corpus)} files, {total:,} bytes), one process each",
    best([[auk, "check", f] for f in corpus], n=max(1, runs // 2)))
row(f"`auk dump ast` of every corpus file, one process each",
    best([[auk, "dump", "ast", f] for f in corpus], n=max(1, runs // 2)))
row(f"`auk ir` (MIR) of the {len(mains)} programs that check clean",
    best([[auk, "ir", f] for f in mains], n=max(1, runs // 2)))
hello = os.path.join(scratch, "hello.auk")
exe = os.path.join(scratch, "a.out")
for name in ["hello", "tour", "life"]:
    row(f"`auk build {name}.auk`", best([[auk, "build", os.path.join(scratch, name + ".auk"), "-o", exe]]),
        "examples/ copy, outside a project")
row("`auk build compiler/src/main.auk`", best([[auk, "build", "compiler/src/main.auk", "-o", exe]]),
    "the pilot front end, 4.5k lines")
row("`auk build examples/hello.auk`", best([[auk, "build", "examples/hello.auk", "-o", exe]], n=1),
    "in the examples project: compiles all of http, json, audio, graphics (one run)")
row("`auk run hello.auk` (startup to exit)", best([[auk, "run", hello]]), "outside a project")
row("`auk run examples/hello.auk`", best([[auk, "run", "examples/hello.auk"]], n=1), "in the examples project (one run)")
row("`auk run -O hello.auk`", best([[auk, "run", "-O", hello]]), "outside a project")
row("`auk run compiler/src/main.auk ast examples/tour.auk`",
    best([[auk, "run", "compiler/src/main.auk", "ast", "examples/tour.auk"]]), "JIT-compile the pilot, then parse")
print("\n".join(rows))
EOF
)"

commit="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- src runtime build.rs Cargo.toml || echo ' (+ uncommitted changes)')"
cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
mem="$(( $(sysctl -n hw.memsize 2>/dev/null || awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo) / 1073741824 ))"
os="$(if command -v sw_vers >/dev/null; then echo "macOS $(sw_vers -productVersion)"; else uname -sr; fi) $(uname -m)"
llvm="$(for c in llvm-config /opt/homebrew/opt/llvm/bin/llvm-config; do command -v "$c" >/dev/null && "$c" --version && break; done 2>/dev/null || echo '?')"

cat > "$OUT" <<EOF
# Perf baseline

The numbers every phase of [the self-hosting plan](self-host-plan.md) compares against (Phase 0).
Written by \`scripts/baseline.sh\`; rerun it on a quiet machine to refresh, and keep older tables
below when a phase changes them.

- **Date:** $(date -u +%Y-%m-%d)
- **Commit:** $commit
- **Machine:** $cpu, $ncpu cores, $mem GB, $os
- **Toolchain:** LLVM $llvm, \`./build.sh\` (the self-hosted compiler)
- **Load average when it started:** $load (a busy machine inflates every number)
- **Method:** best of $RUNS runs (corpus-wide rows: best of $(( RUNS / 2 > 0 ? RUNS / 2 : 1 ))), wall time

## Generated code: bench/perf

\`bench/perf/run.sh\` (see [bench/perf/README.md](../bench/perf/README.md)): the same seven
programs in Auk (\`auk build\`) and Rust (\`-C opt-level=3 -C target-cpu=native\`).

$BENCH

## Compiler

| what | time | note |
|---|---|---|
$COMPILE
EOF
echo "baseline: wrote $OUT" >&2
