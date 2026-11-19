#!/usr/bin/env bash
# Generate runtime/src/cfacts.<os>-<arch>.auk: the C library facts (constants, struct layouts,
# opaque type sizes, pthread initializers, ucontext slots, C macros as raw functions) the
# runtime uses, printed by a C program compiled against this platform's headers with the
# runtime's feature macros (docs/lowlevel.md, section 11). Run once per platform; the output is
# checked in. runtime/test/abi/run.sh checks a checked-in file against the headers again.
#
#   runtime/gen/cfacts.sh [-o <file>]     (default: runtime/src/cfacts.<os>-<arch>.auk)
#
# CC: $CC, else cc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$(uname -s)" in
  Darwin) OS=macos; FLAGS="" ;;
  Linux) OS=linux; FLAGS=-D_GNU_SOURCE ;;
  *) echo "cfacts.sh: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
ARCH="$(uname -m)"
case "$ARCH" in aarch64) ARCH=arm64 ;; amd64) ARCH=x86_64 ;; esac
OUT="$ROOT/runtime/src/cfacts.$OS-$ARCH.auk"
if [ "${1:-}" = "-o" ]; then OUT="$2"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${CC:-cc}" -std=gnu11 -Wall -Werror $FLAGS "$ROOT/runtime/gen/cfacts.c" -o "$TMP/cfacts"
mkdir -p "$(dirname "$OUT")"
"$TMP/cfacts" > "$TMP/out.auk"
mv "$TMP/out.auk" "$OUT"
echo "wrote $OUT"
