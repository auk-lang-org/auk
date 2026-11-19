#!/usr/bin/env bash
# Build Auk without Rust (docs/self-host-plan.md, Phase 6): the runtime (C), then the compiler
# and raft (Auk), from a seed `auk`.
#
#   ./build.sh [--check] [--test] [--install [<dir>]] [--seed <auk> | --from-seed]
#
# Steps:
#   1. runtime   target/auk-rt/libauk_rt.a and auk_rt.bc, from two halves (Phase 7: the runtime
#                moves from C to Auk module by module, docs/lowlevel.md):
#                - runtime/c, with the clang of the LLVM the back end links (as build.rs did):
#                  one translation unit for the files that include each other's code, the
#                  `auk: own translation unit` files alone;
#                - runtime/ (the `auk_rt` package, the modules already ported), with the seed:
#                  `auk build --lib` (an object; `--bc`, bitcode), every `export fn` under its C
#                  name. A seed older than the `raw` dialect can't: then the seed first builds
#                  compiler/ as "stage 0" (target/auk-build/stage0/auk, embedding the C half
#                  only, which `auk build --lib` doesn't use), and stage 0 builds the Auk half.
#                The objects go into one archive, the bitcode is llvm-linked into one module.
#   2. raft      the seed builds raft/ (no dependencies) → target/auk-build/seed-raft, which
#                installs compiler/'s dependencies (compiler/.raft: packages/llvm).
#   3. stage 1   the seed builds compiler/ → target/auk-build/stage1/auk. It runs on the seed's
#                runtime but embeds the new one (step 1).
#   4. stage 2   stage 1 builds compiler/ → target/bin/auk: the new compiler on the new runtime.
#   5. raft      stage 2 builds raft/ → target/bin/raft.
#   --check      also stage 3 (stage 2 builds compiler/): must be bit-identical to stage 2; and
#                stage 2 builds runtime/'s Auk half again, which must be identical to step 1's.
#                If it isn't (the seed is an older compiler that compiles it differently), the
#                whole build runs once more with stage 2 as the seed, so that the runtime stage
#                2 embeds and links is the one its own source compiles.
#   --test       then the tests: the runtime's unit tests (runtime/test/unit/run.sh, Auk) and
#                the integration tests (tests/runner/, built by stage 2) against target/bin/auk and
#                target/bin/raft.
#   --install    then copy auk and raft to <dir> (default ~/.auk/bin; put it on your PATH).
#
# The seed: --seed, else $AUK_SEED, else the target/bin/auk of an earlier build, else `auk` on
# the PATH, else (or with --from-seed) the checked-in seed: seed/<os>-<arch>.bc.gz, the
# compiler as LLVM bitcode (scripts/cut_seed.sh), compiled with clang and linked with cc into
# target/auk-build/seed/auk. A fresh clone needs only LLVM 23 and a C linker.
# LLVM: $LLVM_CONFIG, else Homebrew's llvm@23 (macOS) or llvm-config-23 (Linux).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CHECK=0 TEST=0 INSTALL="" FROM_SEED=0 SEED="${AUK_SEED:-}"
AGAIN=()  # the arguments of a second run (--check), without the seed's
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; AGAIN+=(--check) ;;
    --test) TEST=1; AGAIN+=(--test) ;;
    --install)
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then INSTALL="$2"; shift; else INSTALL="$HOME/.auk/bin"; fi
      AGAIN+=(--install "$INSTALL") ;;
    --seed) SEED="$2"; shift ;;
    --from-seed) FROM_SEED=1 ;;
    -h|--help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '== %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }
ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
secs() { awk -v d=$(( $(ms) - $1 )) 'BEGIN { printf "%.1f s", d / 1000 }'; }

case "$(uname -s)" in
  Darwin) OS=macos; DEFAULT_LLVM_CONFIG=/opt/homebrew/opt/llvm@23/bin/llvm-config ;;
  Linux) OS=linux; DEFAULT_LLVM_CONFIG=llvm-config-23 ;;
  *) die "unsupported OS $(uname -s)" ;;
esac
LLVM_CONFIG="${LLVM_CONFIG:-$DEFAULT_LLVM_CONFIG}"
command -v "$LLVM_CONFIG" > /dev/null || die "no llvm-config at $LLVM_CONFIG (install LLVM 23 or set LLVM_CONFIG)"
LLVM_BIN="$("$LLVM_CONFIG" --bindir)"
CLANG="$LLVM_BIN/clang"
[ -x "$CLANG" ] || die "no clang in $LLVM_BIN"

BUILD="$ROOT/target/auk-build"
mkdir -p "$BUILD" target/auk-rt target/bin

if [ "$FROM_SEED" = 0 ] && [ -z "$SEED" ]; then
  if [ -x target/bin/auk ]; then SEED="$ROOT/target/bin/auk"
  elif command -v auk > /dev/null; then SEED="$(command -v auk)"
  else FROM_SEED=1
  fi
fi
if [ "$FROM_SEED" = 1 ]; then
  ARCH="$(uname -m)"; [ "$ARCH" = aarch64 ] && ARCH=arm64
  bc="seed/$OS-$ARCH.bc.gz"
  [ -f "$bc" ] || die "no auk to start from and no seed for $OS-$ARCH ($bc): pass --seed <auk>"
  t0=$(ms)
  say "seed ($bc, $(sed -n 's/^commit //p' "seed/$OS-$ARCH.txt" | cut -c1-12))"
  mkdir -p "$BUILD/seed"
  gzip -d -c "$bc" > "$BUILD/seed/seed.bc"
  "$CLANG" -c -Wno-override-module "$BUILD/seed/seed.bc" -o "$BUILD/seed/seed.o"
  if [ "$OS" = macos ]; then
    libs=("$("$LLVM_CONFIG" --libdir)/libLLVM.dylib" -framework CoreFoundation -framework Security
      -framework Network -lm -lpthread -Wl,-export_dynamic)
  else
    libs=("$("$LLVM_CONFIG" --libdir)/libLLVM.so" -ldl -lpthread -lm -rdynamic)
  fi
  "${CC:-cc}" "$BUILD/seed/seed.o" "${libs[@]}" -o "$BUILD/seed/auk" || die "linking the seed failed"
  rm -f "$BUILD/seed/seed.bc" "$BUILD/seed/seed.o"
  SEED="$BUILD/seed/auk"
  echo "   target/auk-build/seed/auk ($(secs "$t0"))"
fi
[ -x "$SEED" ] || SEED="$(command -v "$SEED" || true)"
[ -n "$SEED" ] && [ -x "$SEED" ] || die "the seed is not an executable"

# build <by> <source> <out>: through a temporary directory, under the final file name (which
# the macOS linker writes into the code signature)
build() {
  local t tmp; t=$(ms)
  tmp="$(dirname "$3")/.tmp$$"
  mkdir -p "$tmp"
  "$1" build "$2" -o "$tmp/$(basename "$3")" || die "$(basename "$1") failed to build $2"
  mv "$tmp/$(basename "$3")" "$3"
  rmdir "$tmp"
  echo "   ${3#"$ROOT"/} ($(wc -c < "$3" | tr -d ' ') bytes, $(secs "$t"))"
}

# rt_auk <auk> <dir>: runtime/'s Auk half (the `auk_rt` package), built by <auk> into
# <dir>/auk_rt_auk.o and auk_rt_auk.bc; its messages in <dir>/auk.log
rt_auk() {
  mkdir -p "$2"
  "$1" build --lib runtime/src/lib.auk -o "$2/auk_rt_auk.o" > "$2/auk.log" 2>&1 &&
    "$1" build --lib --bc runtime/src/lib.auk -o "$2/auk_rt_auk.bc" >> "$2/auk.log" 2>&1
}

# raft_deps: the seed builds raft (seed-raft), which installs compiler/'s dependencies (once)
RAFT_DONE=0
raft_deps() {
  [ "$RAFT_DONE" = 1 ] && return
  say "raft (built by the seed, $SEED)"
  build "$SEED" raft/src/main.auk "$BUILD/seed-raft"
  (cd compiler && "$BUILD/seed-raft" install > /dev/null) || die "raft install in compiler/ failed"
  RAFT_DONE=1
}

# ---- 1. runtime ----------------------------------------------------------------------------
t0=$(ms)
say "runtime (runtime/c with $CLANG, runtime/src with the seed)"
CDIR="$ROOT/runtime/c"
RT="$BUILD/rt"
rm -rf "$RT"; mkdir -p "$RT"
# macOS: no C file uses blocks since tls.c moved to Auk (clang enables them by default there)
if [ "$OS" = macos ]; then PLATFORM=(-fno-blocks); else PLATFORM=(-D_GNU_SOURCE); fi
FLAGS=(-std=c11 -O2 -fno-strict-aliasing -fno-stack-protector -fPIC -ffunction-sections
  -fdata-sections -Wall -Wextra -Wno-unused-parameter "${PLATFORM[@]}" -I "$CDIR")
units=()
: > "$RT/auk_rt_all.c"
for f in $(LC_ALL=C ls "$CDIR"/*.c); do
  if grep -q "auk: own translation unit" "$f"; then units+=("$f")
  else printf '#include "%s"\n' "$f" >> "$RT/auk_rt_all.c"
  fi
done
units+=("$RT/auk_rt_all.c")
pids=() objs=() bcs=()
for i in "${!units[@]}"; do
  u="${units[$i]}"
  objs+=("$RT/rt_$i.o"); bcs+=("$RT/rt_$i.bc")
  "$CLANG" -c "${FLAGS[@]}" "$u" -o "$RT/rt_$i.o" & pids+=($!)
  "$CLANG" -c -emit-llvm -O2 -std=c11 -fno-strict-aliasing -fno-stack-protector "${PLATFORM[@]}" \
    -I "$CDIR" "$u" -o "$RT/rt_$i.bc" & pids+=($!)
done
c_done() { for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || die "compiling the runtime failed"; done; pids=(); }
# install <dir>: <dir>'s libauk_rt.a and auk_rt.bc into target/auk-rt/, each replaced whole (the
# compiler `#embed`s them from there), never seen half-written
install_rt() {
  for f in libauk_rt.a auk_rt.bc; do
    cp "$1/$f" "target/auk-rt/$f.tmp$$" && mv "target/auk-rt/$f.tmp$$" "target/auk-rt/$f"
  done
}

if ! rt_auk "$SEED" "$RT"; then
  # The seed predates the dialect: stage 0 (compiler/, built by the seed) builds runtime/src.
  # It embeds the C half alone (`auk build --lib` links no runtime).
  echo "   the seed can't build runtime/src ($( (grep -m1 -o "error.*" "$RT/auk.log" || head -1 "$RT/auk.log") | cut -c1-60)): stage 0 will"
  c_done
  mkdir -p "$RT/c-only"
  "$LLVM_BIN/llvm-ar" crs "$RT/c-only/libauk_rt.a" "${objs[@]}"
  "$LLVM_BIN/llvm-link" "${bcs[@]}" -o "$RT/c-only/auk_rt.bc"
  install_rt "$RT/c-only"
  raft_deps
  say "stage 0 (compiler/ on the C half of the runtime, built by the seed)"
  build "$SEED" compiler/src/main.auk "$BUILD/stage0/auk"
  rt_auk "$BUILD/stage0/auk" "$RT" || { cat "$RT/auk.log" >&2; die "building runtime/src failed"; }
fi
c_done
"$LLVM_BIN/llvm-ar" crs "$RT/libauk_rt.a" "${objs[@]}" "$RT/auk_rt_auk.o"
# auk names the target as LLVM's default triple (`arm64-apple-darwin…`), clang normalizes it
# (`arm64-apple-macosx…`): the same target, but llvm-link warns. (rtlink sets the program's.)
"$LLVM_BIN/llvm-link" "${bcs[@]}" "$RT/auk_rt_auk.bc" -o "$RT/auk_rt.bc" 2> "$RT/link.log" ||
  { cat "$RT/link.log" >&2; die "linking the runtime's bitcode failed"; }
grep -v -e "different target triples" -e '^$' "$RT/link.log" >&2 || true
install_rt "$RT"
echo "   target/auk-rt/libauk_rt.a, auk_rt.bc ($(secs "$t0"))"

# ---- 2. raft, and compiler/'s dependencies -------------------------------------------------
raft_deps

# ---- 3, 4. the compiler --------------------------------------------------------------------
say "stage 1 (compiler/, built by the seed)"
build "$SEED" compiler/src/main.auk "$BUILD/stage1/auk"
say "stage 2 (compiler/, built by stage 1)"
build "$BUILD/stage1/auk" compiler/src/main.auk "$BUILD/stage2/auk"
cp "$BUILD/stage2/auk" target/bin/auk.tmp && mv target/bin/auk.tmp target/bin/auk

# ---- 5. raft -------------------------------------------------------------------------------
say "raft (built by stage 2)"
build target/bin/auk raft/src/main.auk "$BUILD/raft"
cp "$BUILD/raft" target/bin/raft.tmp && mv target/bin/raft.tmp target/bin/raft

if [ "$CHECK" = 1 ]; then
  say "stage 3 (compiler/, built by stage 2)"
  build target/bin/auk compiler/src/main.auk "$BUILD/stage3/auk"
  if cmp -s "$BUILD/stage2/auk" "$BUILD/stage3/auk"; then
    echo "   stage 2 and stage 3 are bit-identical"
  else
    die "stage 2 and stage 3 differ: $(cmp "$BUILD/stage2/auk" "$BUILD/stage3/auk" | head -1)"
  fi
  say "runtime/src (built by stage 2)"
  rt_auk target/bin/auk "$BUILD/rt-check" || { cat "$BUILD/rt-check/auk.log" >&2; die "stage 2 failed to build runtime/src"; }
  if cmp -s "$RT/auk_rt_auk.o" "$BUILD/rt-check/auk_rt_auk.o" &&
    cmp -s "$RT/auk_rt_auk.bc" "$BUILD/rt-check/auk_rt_auk.bc"; then
    echo "   the same as step 1's"
  elif [ -n "${AUK_BUILD_AGAIN:-}" ]; then
    die "stage 2 builds runtime/src differently from step 1, even with stage 2 as the seed"
  else
    echo "   not the same as the seed's: building again with stage 2 as the seed"
    mkdir -p "$BUILD/seed-again"
    cp "$BUILD/stage2/auk" "$BUILD/seed-again/auk"
    AUK_BUILD_AGAIN=1 exec "$0" --seed "$BUILD/seed-again/auk" ${AGAIN[@]+"${AGAIN[@]}"}
  fi
fi
if [ "$TEST" = 1 ]; then
  say "runtime tests (runtime/test/unit)"
  sh runtime/test/unit/run.sh | tail -1
  say "integration tests (tests/runner, against target/bin/auk and target/bin/raft)"
  build target/bin/auk tests/runner/src/main.auk "$BUILD/test-runner"
  log="$BUILD/test-runner.log"
  if AUK_BIN="$ROOT/target/bin/auk" RAFT_BIN="$ROOT/target/bin/raft" "$BUILD/test-runner" > "$log" 2>&1; then
    tail -1 "$log"
  else
    grep -A8 '^FAIL' "$log" | head -60
    tail -1 "$log"
    die "integration tests failed (the whole output: ${log#"$ROOT"/})"
  fi
fi
if [ -n "$INSTALL" ]; then
  say "install ($INSTALL)"
  mkdir -p "$INSTALL"
  for b in auk raft; do
    # a new file, then a rename: a running auk keeps its old binary
    cp "target/bin/$b" "$INSTALL/.$b.tmp$$" && mv "$INSTALL/.$b.tmp$$" "$INSTALL/$b"
  done
  # raft's package registry: this checkout's packages/ (raft finds it through this file)
  echo "$ROOT/packages" > "$INSTALL/raft.registry"
  echo "   $INSTALL/auk, $INSTALL/raft (registry: $ROOT/packages)"
  case ":$PATH:" in
    *":$INSTALL:"*) ;;
    *) echo "   $INSTALL is not on your PATH: add  export PATH=\"$INSTALL:\$PATH\"  to your shell profile" ;;
  esac
fi
say "done: target/bin/auk, target/bin/raft"
