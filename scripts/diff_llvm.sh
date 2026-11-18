#!/usr/bin/env bash
# LLVM IR of the self-hosted back end (docs/self-host-plan.md, Phase 4): for every back-end
# program, the Auk port (`compiler llvm`) compiles the Rust compiler's MIR dump to LLVM IR at each
# level, and the text must equal `auk ir --llvm=<level>`'s:
#   the MIR `auk run` compiles: o0 (what `auk ir --llvm` prints), o0-raw (before any pass),
#                                light-raw, light, o2, o3
#   `auk build`'s (--release):  build (O2 with the runtime's bitcode), build-raw
#   `auk build -g`'s:           build (DWARF)
#   a traced run's, a debugger run's: o0, light
# Usage: scripts/diff_llvm.sh [-j N] [regex]   (regex: only matching programs)
source "$(dirname "$0")/pilot_common.sh"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
[ "${1:-}" = -j ] && { JOBS="$2"; shift 2; }
ONLY="${1:-}"
out="$ROOT/target/pilot/llvm"

# one job: <program> <dump options> <level>
job() {
  local f="$1" v="${2#-}" lv="$3"
  local key="${f//\//_}${v// /}.$lv"
  local dump="$out/${f//\//_}${v// /}.dump"
  # shellcheck disable=SC2086  # the variant's options are words
  "$AUK" ir $v --llvm="$lv" "$f" > "$out/$key.rust" 2>&1 || true
  "$PORT" llvm --level "$lv" "$dump" > "$out/$key.auk" 2>&1 || true
  if cmp -s "$out/$key.rust" "$out/$key.auk"; then
    echo "same $f $v $lv $(wc -l < "$out/$key.rust")"
    rm -f "$out/$key.rust" "$out/$key.auk"
  else
    echo "DIFF $f $v $lv ($(diff "$out/$key.rust" "$out/$key.auk" | grep -c '^[<>]') lines; diff $out/$key.rust $out/$key.auk)"
  fi
}

if [ "${DIFF_LLVM_JOB:-}" = 1 ]; then
  job "$@"
  exit 0
fi

build_both
rm -rf "$out"
mkdir -p "$out"
progs=$(backend_corpus | { if [ -n "$ONLY" ]; then grep -E "$ONLY" || true; else cat; fi; })
# the dumps first (each variant once), then every (program, variant, level) in parallel
for f in $progs; do
  for v in "" "--release" "--release -g" "--trace=json" "--debug"; do
    # shellcheck disable=SC2086
    "$AUK" dump mir $v "$f" > "$out/${f//\//_}${v// /}.dump" 2>&1 || true
  done
done
for f in $progs; do
  for lv in o0 o0-raw light-raw light o2 o3; do printf '%s\t-%s\t%s\n' "$f" "" "$lv"; done
  for lv in build build-raw; do printf '%s\t-%s\t%s\n' "$f" "--release" "$lv"; done
  printf '%s\t-%s\t%s\n' "$f" "--release -g" build
  for v in "--trace=json" "--debug"; do
    for lv in o0 light; do printf '%s\t-%s\t%s\n' "$f" "$v" "$lv"; done
  done
done > "$out/jobs.tsv"
export DIFF_LLVM_JOB=1
tr '\t\n' '\0\0' < "$out/jobs.tsv" | xargs -0 -n 3 -P "$JOBS" "$0" > "$out/results.txt"
n=$(wc -l < "$out/results.txt" | tr -d ' ')
bad=$(grep -c '^DIFF' "$out/results.txt" || true)
grep '^DIFF' "$out/results.txt" | LC_ALL=C sort || true
echo "llvm: $(echo "$progs" | wc -w | tr -d ' ') programs, $n IR texts, $bad differ"
[ "$bad" -eq 0 ]
