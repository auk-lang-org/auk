#!/usr/bin/env bash
# Checks runtime/src/abi.auk and this platform's runtime/src/cfacts.<os>-<arch>.auk against C:
#
# 1. a project of the runtime package (`auk_rt`) with both files compiles (`auk check`: every
#    `raw assert` in them holds);
# 2. tables.awk turns every struct, field, constant and initializer they declare into a probe:
#    an Auk library (`auk build --lib`) returning raw.size_of/align_of/offset_of and the values,
#    and C code comparing them with sizeof/_Alignof/offsetof and the macros, compiled with the
#    real runtime/c/auk_rt.h (and task.c's and chan.c's structs as they were: probe.c) and the system headers
#    with the runtime's feature macros; probe.c adds the functions (W*, S_IS*, CMSG_*, the
#    ucontext slots, errno, stdout, the abi helpers, structs by value both ways);
# 3. every checked-in cfacts file declares the same public items above its "only on <os>" part.
#
#   runtime/test/abi/run.sh [<auk>]     (default: target/bin/auk)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AUK="${1:-$ROOT/target/bin/auk}"
HERE="$ROOT/runtime/test/abi"
case "$(uname -s)" in
  Darwin) OS=macos; FLAGS="" ;;
  Linux) OS=linux; FLAGS="-D_GNU_SOURCE -lpthread -ldl" ;;
  *) echo "run.sh: unsupported OS" >&2; exit 1 ;;
esac
ARCH="$(uname -m)"
case "$ARCH" in aarch64) ARCH=arm64 ;; amd64) ARCH=x86_64 ;; esac
CFACTS="$ROOT/runtime/src/cfacts.$OS-$ARCH.auk"
[ -f "$CFACTS" ] || { echo "run.sh: no $CFACTS (run runtime/gen/cfacts.sh)" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src"
printf '[package]\nname = "auk_rt"\nversion = "0.1.0"\neffects = ["raw", "ffi"]\n' > "$T/raft.toml"
cp "$ROOT/runtime/src/abi.auk" "$CFACTS" "$T/src/"

# 1. the files compile, their raw asserts hold
"$AUK" check "$T/src/abi.auk"

# 2. the probe
awk -v AUK="$T/tables.auk" -v C="$T/tables.c" -f "$HERE/tables.awk" "$ROOT/runtime/src/abi.auk" "$CFACTS"
cat "$HERE/probe.auk" "$T/tables.auk" > "$T/src/main.auk"
"$AUK" build --lib "$T/src/main.auk" -o "$T/probe.o"
{
  [ "$OS" = linux ] && echo '#define _GNU_SOURCE'
  for h in dirent dlfcn errno fcntl limits netdb netinet/in poll pthread setjmp signal spawn stdint \
    stdio stdlib string sys/ioctl sys/mman sys/socket sys/stat sys/time sys/un sys/wait time unistd; do
    echo "#include <$h.h>"
  done
  if [ "$OS" = macos ]; then
    printf '#include <dispatch/dispatch.h>\n#include <sys/ucontext.h>\n'
  else
    printf '#include <elf.h>\n#include <link.h>\n#include <sys/auxv.h>\n#include <ucontext.h>\n'
  fi
  echo '#include "auk_rt.h"'
  cat "$HERE/probe.c"
} > "$T/probe_all.c"
# shellcheck disable=SC2086
cc -std=gnu11 -w -I "$ROOT/runtime/c" -I "$T" "$T/probe_all.c" "$T/probe.o" -o "$T/probe" $FLAGS
"$T/probe"

# 3. the same public items on every platform
sig() {
  awk '/^\/\/ ---- only on/ { exit }
       /^pub raw (struct|union) / { s = $4; print s; ins = 1; next }
       ins && /^}/ { ins = 0; next }
       ins { f = $1; sub(/:$/, "", f); if (f !~ /^_pad/ && f !~ /^w[0-9]*$/) print s "." f; next }
       /^pub (raw let|fn) / { n = $1 == "pub" && $2 == "fn" ? $3 : $4; sub(/[:(].*/, "", n); print n }' "$1" | sort
}
first=""
for f in "$ROOT"/runtime/src/cfacts.*.auk; do
  if [ -z "$first" ]; then first="$f"; sig "$f" > "$T/sig0"; continue; fi
  sig "$f" > "$T/sig1"
  if ! diff "$T/sig0" "$T/sig1" > "$T/sigdiff"; then
    echo "FAIL $(basename "$first") and $(basename "$f") declare different public items:"
    cat "$T/sigdiff"
    exit 1
  fi
done
echo "ok: abi.auk and $(basename "$CFACTS") match C"
