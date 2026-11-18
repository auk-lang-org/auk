#!/usr/bin/env bash
# The bootstrap fixed point (docs/self-host-plan.md, Phase 4): the Rust `auk` builds the Auk
# compiler (compiler/) into stage 1; stage 1 builds it into stage 2; stage 2 builds it into
# stage 3. Stages 2 and 3 are the same compiler built by the same compiler, so they must be
# bit-identical (deterministic output: no hash order, timestamps or temp paths in them). Prints
# each stage's build time and size, and whether stage 1 (built by Rust) matches too.
#
#   scripts/bootstrap.sh [--no-build] [--perf]
#     --no-build  skip `cargo build --release`
#     --perf      also build bench/perf/auk/*.auk with the Rust `auk` and with stage 2: the
#                 executables must be identical (the generated-code gate)
#
# The stages are target/stage{1,2,3}/auk: the same file name, which the macOS linker puts in the
# code signature (its identifier); copied to target/auk-stage{1,2,3}. Exit 1 if stage 2 and 3
# (or, with --perf, a benchmark's executables) differ.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BUILD=1 PERF=0
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    --perf) PERF=1 ;;
    *) echo "bootstrap.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done
if [ "$BUILD" = 1 ]; then cargo build --release -q; fi
[ -d compiler/.raft ] || (cd compiler && "$ROOT/target/release/raft" install)
ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
size() { wc -c < "$1" | tr -d ' '; }
# build <compiler> <source> <out>: time one `auk build`
build() {
  local by="$1" src="$2" out="$3" t0 t1
  rm -f "$out"
  mkdir -p "$(dirname "$out")"
  t0=$(ms)
  "$by" build "$src" -o "$out"
  t1=$(ms)
  printf '%-24s built by %-24s in %6.1f s, %s bytes\n' "${out#target/}" "${by#"$ROOT"/}" \
    "$(awk -v d=$((t1 - t0)) 'BEGIN { print d / 1000 }')" "$(size "$out")"
}
build "$ROOT/target/release/auk" compiler/src/main.auk target/stage1/auk
build "$ROOT/target/stage1/auk" compiler/src/main.auk target/stage2/auk
build "$ROOT/target/stage2/auk" compiler/src/main.auk target/stage3/auk
for n in 1 2 3; do cp "target/stage$n/auk" "target/auk-stage$n"; done
if cmp -s target/stage1/auk target/stage2/auk; then
  echo "stage 1 (built by Rust) and stage 2: identical"
else
  echo "stage 1 (built by Rust) and stage 2: differ"
fi
status=0
if cmp -s target/stage2/auk target/stage3/auk; then
  echo "bootstrap: stage 2 and stage 3 are bit-identical"
else
  echo "bootstrap: stage 2 and stage 3 DIFFER ($(cmp target/stage2/auk target/stage3/auk | head -1))"
  status=1
fi
if [ "$PERF" = 1 ]; then
  for f in bench/perf/auk/*.auk; do
    b="$(basename "$f" .auk)"
    build "$ROOT/target/release/auk" "$f" "target/bootstrap/rust/$b"
    build "$ROOT/target/stage2/auk" "$f" "target/bootstrap/auk/$b"
    if cmp -s "target/bootstrap/rust/$b" "target/bootstrap/auk/$b"; then
      echo "perf $b: identical executables"
    else
      echo "perf $b: executables DIFFER"
      status=1
    fi
  done
fi
exit "$status"
