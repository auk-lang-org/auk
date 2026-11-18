#!/usr/bin/env bash
# The golden corpus (docs/self-host-plan.md, Phase 0): what the Rust `auk` makes of every .auk
# file in tests/, examples/, packages/ (without .raft/ copies), src/prelude/ and compiler/, saved
# so a port of the compiler (Phases 3-5) can be diffed against it.
#
#   scripts/golden.sh                     record target/golden/rust with target/release/auk
#   scripts/golden.sh --compare <auk>     record target/golden/compare with <auk> (same CLI),
#                                         re-record the Rust reference, and report differences
#                                         (exit 1 on any)
# Options:
#   --modes m,m,...   only these modes (default: all of tokens,ast,check,ir,fmt,run)
#   --only <regex>    only corpus files / run entries whose path or name matches (grep -E)
#   --reuse           --compare: keep an existing target/golden/rust instead of re-recording it
#   --no-build        don't run `cargo build --release` first
#   -j N              parallel jobs (default: the number of CPUs)
#
# Modes, one output file per corpus file at target/golden/<label>/<mode>/<path>:
#   tokens  `auk dump tokens <f>`      ast  `auk dump ast <f>`
#   check   `auk check <f> --json`     fmt  `auk fmt -` < f (stdout; the file is not touched)
#   ir      `auk ir <f>` (MIR text), for files that check clean and have a `main`
#   run     `auk run`/`auk test` of the entries in scripts/golden_runs.txt, at run/<name>
# Each output file is the command's stdout, then "=== stderr ===" and its stderr if any, then
# "=== exit N ===" if the exit code isn't 0. The repo root becomes <root>, temp directories
# <tmp>, and the binary's path <auk>.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/golden.sh"
ALL_MODES="tokens ast check ir fmt run"

# capture <outfile> <stdin> <cmd...>: run cmd, write the normalized record to outfile.
capture() {
  local out="$1" in="$2"; shift 2
  local tmp="$out.tmp" code=0
  mkdir -p "$(dirname "$out")"
  ( cd "$ROOT" && exec timeout 300 "$@" < "$in" > "$tmp.o" 2> "$tmp.e" ) || code=$?
  {
    cat "$tmp.o"
    if [ -s "$tmp.e" ]; then
      [ -s "$tmp.o" ] && [ "$(tail -c 1 "$tmp.o" | od -An -c | tr -d ' ')" != '\n' ] && echo
      echo "=== stderr ==="
      cat "$tmp.e"
    fi
    if [ "$code" -ne 0 ]; then
      if [ -s "$tmp.e" ] || [ -s "$tmp.o" ]; then
        local last="$tmp.o"; [ -s "$tmp.e" ] && last="$tmp.e"
        [ "$(tail -c 1 "$last" | od -An -c | tr -d ' ')" != '\n' ] && echo
      fi
      echo "=== exit $code ==="
    fi
  } | LC_ALL=C sed -e "s|$BIN_ABS|<auk>|g" -e "s|$ROOT|<root>|g" \
        -e 's|/private/var/folders/[^/]*/[^/]*/T/[^/ :"]*|<tmp>|g' \
        -e 's|/var/folders/[^/]*/[^/]*/T/[^/ :"]*|<tmp>|g' \
        -e 's|/tmp/[^/ :"]*|<tmp>|g' > "$out"
  rm -f "$tmp.o" "$tmp.e"
  return 0
}

has_mode() { case " $MODES " in *" $1 "*) return 0 ;; esac; return 1; }

# --file <label> <file>: every per-file mode for one corpus file.
worker_file() {
  local f="$1" o="$OUT" check_tmp
  has_mode tokens && capture "$o/tokens/$f" /dev/null "$BIN" dump tokens "$f"
  has_mode ast && capture "$o/ast/$f" /dev/null "$BIN" dump ast "$f"
  has_mode fmt && capture "$o/fmt/$f" "$ROOT/$f" "$BIN" fmt -
  if has_mode check || has_mode ir; then
    check_tmp="$o/check/$f"
    has_mode check || check_tmp="$o/.scratch/$f"
    capture "$check_tmp" /dev/null "$BIN" check "$f" --json
    if has_mode ir && head -1 "$check_tmp" | grep -q '"ok":true' \
        && grep -Eq '^(pub )?(async )?fn main\(' "$ROOT/$f"; then
      capture "$o/ir/$f" /dev/null "$BIN" ir "$f"
    fi
  fi
}

# --run <line>: one entry of golden_runs.txt.
worker_run() {
  local line="$1" name kind rest stdin=/dev/null
  read -r name kind rest <<< "$line"
  if [[ "$rest" == *" < "* ]]; then
    stdin="$ROOT/${rest##* < }"
    rest="${rest% < *}"
  fi
  # shellcheck disable=SC2086  # the arguments are whitespace-separated by design
  capture "$OUT/run/$name" "$stdin" "$BIN" "$kind" $rest
}

if [ "${1:-}" = "--worker" ]; then
  shift
  BIN="$1" BIN_ABS="$1" OUT="$2" MODES="$3" what="$4"; shift 4
  for x in "$@"; do
    if [ "$what" = file ]; then worker_file "$x"; else worker_run "$x"; fi
  done
  exit 0
fi

# ---- driver ----
MODES="$ALL_MODES" ONLY="" COMPARE="" REUSE=0 BUILD=1
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
while [ $# -gt 0 ]; do
  case "$1" in
    --modes) MODES="${2//,/ }"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --compare) COMPARE="$2"; shift 2 ;;
    --reuse) REUSE=1; shift ;;
    --no-build) BUILD=0; shift ;;
    -j) JOBS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "golden.sh: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
for m in $MODES; do
  case " $ALL_MODES " in *" $m "*) ;; *) echo "golden.sh: unknown mode $m" >&2; exit 2 ;; esac
done

cd "$ROOT"
export LC_ALL=C TZ=UTC NO_COLOR=1
unset AUK_LEAK_CHECK AUK_DEBUG AUK_LINKER AUK_NO_RT_INLINE 2>/dev/null || true

corpus() {
  find tests examples packages src/prelude compiler -name '*.auk' -not -path '*/.raft/*' \
    | LC_ALL=C sort | { if [ -n "$ONLY" ]; then grep -E "$ONLY" || true; else cat; fi; }
}
runs() {
  grep -v '^#' scripts/golden_runs.txt | grep -v '^[[:space:]]*$' \
    | { if [ -n "$ONLY" ]; then grep -E "$ONLY" || true; else cat; fi; }
}

# record <auk> <label>: write target/golden/<label>.
record() {
  local bin="$1" label="$2" out="$ROOT/target/golden/$2" start=$SECONDS
  local file_modes="${MODES/run/}"
  rm -rf "$out"
  mkdir -p "$out"
  if [ -n "${file_modes// /}" ]; then
    corpus | xargs -P "$JOBS" -n 4 "$SELF" --worker "$bin" "$out" "$MODES" file
  fi
  if has_mode run; then
    runs | tr '\n' '\0' | xargs -0 -P "$JOBS" -n 1 "$SELF" --worker "$bin" "$out" "$MODES" run
  fi
  rm -rf "$out/.scratch"
  local summary=""
  for m in $MODES; do
    [ -d "$out/$m" ] && summary+=" $m=$(find "$out/$m" -type f | wc -l | tr -d ' ')"
  done
  echo "golden: recorded $label with $bin in $((SECONDS - start))s:$summary"
}

if [ "$BUILD" = 1 ]; then cargo build --release -q; fi
RUST="$ROOT/target/release/auk"

if [ -z "$COMPARE" ]; then
  record "$RUST" rust
  exit 0
fi

case "$COMPARE" in */*) ;; *) COMPARE="$(command -v "$COMPARE" || echo "$COMPARE")" ;; esac
OTHER="$(cd "$(dirname "$COMPARE")" && pwd)/$(basename "$COMPARE")"
[ -x "$OTHER" ] || { echo "golden.sh: $COMPARE is not an executable" >&2; exit 2; }
if [ "$REUSE" = 0 ] || [ ! -d target/golden/rust ]; then record "$RUST" rust; fi
record "$OTHER" compare

REF="$ROOT/target/golden/rust" NEW="$ROOT/target/golden/compare" total=0

# compared <mode>: the outputs to compare (with --only, just the selected ones): every corpus
# file, every run entry, and for ir the files either side has an output for.
compared() {
  case "$1" in
    run) runs | awk '{print $1}' ;;
    ir) { [ -d "$REF/ir" ] && (cd "$REF/ir" && find . -type f); [ -d "$NEW/ir" ] && (cd "$NEW/ir" && find . -type f); } \
          | sed 's|^\./||' | LC_ALL=C sort -u | LC_ALL=C comm -12 - <(corpus) ;;
    *) corpus ;;
  esac
}

# Report: per mode, the files that differ (or exist on one side only) and their first diff lines.
for m in $MODES; do
  n=0 bad=0 shown=0
  while read -r rel; do
    n=$((n + 1))
    a="$REF/$m/$rel" b="$NEW/$m/$rel"
    if [ -f "$a" ] && [ -f "$b" ] && cmp -s "$a" "$b"; then continue; fi
    bad=$((bad + 1))
    if [ "$shown" -lt 20 ]; then
      shown=$((shown + 1))
      if [ ! -f "$b" ]; then echo "  $m: $rel: missing from compare"
      elif [ ! -f "$a" ]; then echo "  $m: $rel: missing from rust"
      else
        echo "  $m: $rel ($( (diff "$a" "$b" || true) | grep -c '^[<>]') lines differ; diff ${a#$ROOT/} ${b#$ROOT/})"
        { diff "$a" "$b" || true; } | head -6 | sed 's/^/      /' | cut -c1-200
      fi
    fi
  done < <(compared "$m")
  [ "$bad" -gt "$shown" ] && echo "  $m: ... and $((bad - shown)) more"
  echo "golden $m: $n files, $bad differ"
  total=$((total + bad))
done
[ "$total" -eq 0 ]
