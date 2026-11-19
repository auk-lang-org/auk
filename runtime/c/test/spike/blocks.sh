#!/bin/sh
# Run the Phase 7b blocks spike (blocks.c): Network.framework TLS with hand-made blocks,
# compiled without -fblocks: under ASan + UBSan, under leaks(1), and without block signatures.
#
#   sh runtime/c/test/spike/blocks.sh
#
# macOS only. Needs `openssl` (for the self-signed certificate and `s_server`). CC overrides the
# compiler; by default Homebrew's clang (/opt/homebrew/opt/llvm@23/bin/clang) when present.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/auk_spike_blocks.XXXXXX")
server=""
cleanup() {
    [ -n "$server" ] && kill "$server" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

cc=${CC:-/opt/homebrew/opt/llvm@23/bin/clang}
[ -x "$cc" ] || cc=cc

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
    -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
    -addext extendedKeyUsage=serverAuth -addext basicConstraints=critical,CA:TRUE \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl x509 -in "$work/cert.pem" -outform DER -out "$work/cert.der"

port=$((20000 + $$ % 20000))
openssl s_server -accept "127.0.0.1:$port" -cert "$work/cert.pem" -key "$work/key.pem" -rev -quiet \
    </dev/null >"$work/server.log" 2>&1 &
server=$!
i=0
while ! nc -z 127.0.0.1 "$port" 2>/dev/null; do
    i=$((i + 1))
    [ $i -gt 50 ] && { echo "s_server did not start"; cat "$work/server.log"; exit 1; }
    sleep 0.1
done

# -fno-blocks: clang enables blocks by default on Darwin; the point of the spike is not to use them
fw="-framework Network -framework Security -framework CoreFoundation"
src="$here/blocks.c"
base="-std=c11 -O1 -g -Wall -Wextra -fno-blocks"

# 1. ASan + UBSan. LeakSanitizer is off: on macOS it can't see thread-specific data or the
# frameworks' dispatch_once singletons, so it reports ~35 framework-internal "leaks" (boringssl
# error state, CF preference caches, nw_context), none from this file's blocks or structs;
# step 2 checks leaks instead.
echo "== ASan + UBSan"
"$cc" $base -fsanitize=address,undefined -fno-omit-frame-pointer "$src" -o "$work/asan" $fw
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$work/asan" "$port" "$work/cert.der"

# 2. leaks(1), Apple's scanning leak checker, on a plain build
echo "== leaks --atExit"
cc $base "$src" -o "$work/plain" $fw
if ! MallocStackLogging=1 leaks --atExit -- "$work/plain" "$port" "$work/cert.der" >"$work/leaks.txt" 2>&1; then
    cat "$work/leaks.txt"
    exit 1
fi
grep -E "^(ok|FAIL|PASS)| leaks for " "$work/leaks.txt"

# 3. no BLOCK_HAS_SIGNATURE: nothing used here reads the signature string
echo "== without block signatures"
cc $base -DSPIKE_NO_SIGNATURE "$src" -o "$work/nosig" $fw
"$work/nosig" "$port" "$work/cert.der"
