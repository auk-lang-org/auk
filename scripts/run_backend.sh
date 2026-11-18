#!/usr/bin/env bash
# Programs compiled by the self-hosted back end behave as the Rust compiler's (docs/self-host-
# plan.md, Phase 4). For every `run` and `test` entry of scripts/golden_runs.txt (a project
# directory's tests, not the flat `examples` directory) and every compiler/tests/backend/
# program, the Rust compiler writes the MIR (`auk dump mir [--test]`) and the port compiles it
# in memory and runs it in its own process (`compiler run`: `auk run`'s light level, `auk test`'s
# O0); stdout, stderr and the exit code must equal `auk run`/`auk test`'s. Every `run` program is
# also built by both (`auk build`, and `compiler build` on `auk dump mir --release`) and the two
# executables' outputs compared.
# Usage: scripts/run_backend.sh [-j N] [regex]   (regex: only matching entry names)
source "$(dirname "$0")/pilot_common.sh"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
[ "${1:-}" = -j ] && { JOBS="$2"; shift 2; }
ONLY="${1:-}"
out="$ROOT/target/pilot/run"

# run <out> <stdin> <cmd...>: the command's stdout and stderr, then its exit code
run() {
  local o="$1" in="$2"
  shift 2
  "$@" < "$in" > "$o" 2>&1 && echo "=== exit 0" >> "$o" || echo "=== exit $?" >> "$o"
}

# one job: an entry line of golden_runs.txt
job() {
  local name kind target rest stdin=/dev/null
  read -r name kind target rest <<< "$1"
  if [[ "$rest" == *"< "* ]]; then
    stdin="$ROOT/${rest##*< }"
    rest="${rest%%< *}"
  fi
  [[ "$target" == *"< "* ]] && { stdin="$ROOT/${target##*< }"; target="${target%% *}"; }
  local d="$out/$name"
  mkdir -p "$d"
  # shellcheck disable=SC2086  # the program's arguments are words
  if [ "$kind" = test ]; then
    run "$d/rust" "$stdin" "$AUK" test "$target"
    "$AUK" dump mir --test "$target" > "$d/mir" 2> "$d/mir.err"
    local argv0="$target"
    [ -d "$target" ] && argv0="$target/src/lib.auk"
    run "$d/auk" "$stdin" "$PORT" run --level o0 --argv0 "$argv0" "$d/mir"
  else
    run "$d/rust" "$stdin" "$AUK" run "$target" $rest
    "$AUK" dump mir "$target" > "$d/mir" 2> "$d/mir.err"
    run "$d/auk" "$stdin" "$PORT" run --argv0 "$target" "$d/mir" $rest
  fi
  local verdict=same
  cmp -s "$d/rust" "$d/auk" || verdict="DIFF $name (jit; diff $d/rust $d/auk)"
  if [ "$kind" = run ] && [ "$verdict" = same ]; then
    "$AUK" build "$target" -o "$d/exe.rust" > "$d/build.rust" 2>&1 || true
    "$AUK" dump mir --release "$target" > "$d/mir.release" 2> "$d/mir.err"
    "$PORT" build "$d/mir.release" -o "$d/exe.auk" > "$d/build.auk" 2>&1 || true
    run "$d/out.rust" "$stdin" "$d/exe.rust" $rest
    run "$d/out.auk" "$stdin" "$d/exe.auk" $rest
    cmp -s "$d/out.rust" "$d/out.auk" || verdict="DIFF $name (build; diff $d/out.rust $d/out.auk)"
  fi
  echo "$verdict"
  [ "$verdict" = same ] && rm -rf "$d"
  return 0
}

if [ "${RUN_BACKEND_JOB:-}" = 1 ]; then
  job "$1"
  exit 0
fi

build_both
rm -rf "$out"
mkdir -p "$out"
{
  grep -v '^#' scripts/golden_runs.txt | grep -v '^[[:space:]]*$' \
    | awk '$2 == "run" || ($2 == "test" && $3 != "examples")'
  for f in $(find compiler/tests/backend -name '*.auk' | LC_ALL=C sort); do
    echo "backend_$(basename "$f" .auk) run $f"
  done
} | { if [ -n "$ONLY" ]; then grep -E "$ONLY" || true; else cat; fi; } > "$out/entries.txt"
export RUN_BACKEND_JOB=1
tr '\n' '\0' < "$out/entries.txt" | xargs -0 -n 1 -P "$JOBS" "$0" > "$out/results.txt"
n=$(wc -l < "$out/results.txt" | tr -d ' ')
bad=$(grep -c '^DIFF' "$out/results.txt" || true)
grep '^DIFF' "$out/results.txt" | LC_ALL=C sort || true
echo "run: $n programs, $bad differ"
[ "$bad" -eq 0 ]
