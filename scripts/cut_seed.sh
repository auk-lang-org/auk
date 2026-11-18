#!/usr/bin/env bash
# Cut the bootstrap seed for this platform (docs/self-host-plan.md, Phase 6): the compiler as
# LLVM bitcode, so a fresh clone builds with LLVM and a C linker alone (`./build.sh` uses it
# when there is no `auk` to start from).
#
#   scripts/cut_seed.sh
#
# Runs `./build.sh --check` first (the seed is cut from the fixed point), then has stage 2 build
# compiler/ once more with AUK_EMIT_BC (the module the object file is made from: the compiler,
# with the prelude, docs and runtime archive it embeds) and links the runtime's own bitcode
# (target/auk-rt/auk_rt.bc) into it: seed/<os>-<arch>.bc.xz, plus seed/<os>-<arch>.txt (the
# commit, date and sha256 of the bitcode). Then checks it: the seed, compiled and linked as
# build.sh does, must build a stage 2 identical to the one it was cut from.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "$(uname -s)" in Darwin) OS=macos ;; Linux) OS=linux ;; *) echo "unsupported OS" >&2; exit 1 ;; esac
ARCH="$(uname -m)"; [ "$ARCH" = aarch64 ] && ARCH=arm64
NAME="$OS-$ARCH"
LLVM_CONFIG="${LLVM_CONFIG:-$([ "$OS" = macos ] && echo /opt/homebrew/opt/llvm@23/bin/llvm-config || echo llvm-config-23)}"
LLVM_BIN="$("$LLVM_CONFIG" --bindir)"
[ -z "$(git status --porcelain -- compiler runtime packages/llvm)" ] ||
  { echo "cut_seed: commit compiler/, runtime/ and packages/llvm first (the seed names its commit)" >&2; exit 1; }

./build.sh --check
W="$ROOT/target/auk-build/seed-cut"
rm -rf "$W"; mkdir -p "$W"
AUK_EMIT_BC="$W/prog.bc" target/bin/auk build compiler/src/main.auk -o "$W/auk"
"$LLVM_BIN/llvm-link" "$W/prog.bc" target/auk-rt/auk_rt.bc -o "$W/seed.bc" 2> /dev/null
mkdir -p seed
xz -9 -T0 -c "$W/seed.bc" > "seed/$NAME.bc.xz"
{
  echo "commit $(git rev-parse HEAD)"
  echo "date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "sha256 $(shasum -a 256 "$W/seed.bc" | cut -d' ' -f1)"
  echo "llvm $("$LLVM_CONFIG" --version)"
} > "seed/$NAME.txt"
echo "seed/$NAME.bc.xz: $(wc -c < "seed/$NAME.bc.xz" | tr -d ' ') bytes ($(wc -c < "$W/seed.bc" | tr -d ' ') uncompressed)"

# check: build from the seed alone, as a fresh clone would
cp target/auk-build/stage2/auk "$W/stage2-ref"
./build.sh --from-seed
if cmp -s "$W/stage2-ref" target/auk-build/stage2/auk; then
  echo "cut_seed: the seed builds the same stage 2"
else
  echo "cut_seed: the seed's stage 2 DIFFERS from the one it was cut from" >&2
  exit 1
fi
