#!/usr/bin/env bash
# Link an executable with the system linker, called directly: no C compiler driver
# (docs/self-host-plan.md, 7d). The same command line `auk build` makes
# (compiler/src/native.auk; keep the two in step):
#   macOS  Apple's ld (the Command Line Tools'): -arch, -platform_version macos <min> <sdk>,
#          -syslibroot <the SDK>, -lSystem (which brings the C start code), -export_dynamic.
#   Linux  ld.lld (LLVM's lld: LLVM's bindir, else the PATH), else binutils' ld: a PIE with the C
#          library's start files (Scrt1.o, crti.o, crtn.o: libc6-dev), its dynamic linker and
#          directories, --export-dynamic.
#
#   scripts/link.sh <cc-style arguments>   # as a C compiler driver for linking: objects,
#                                          # libraries, -l/-L/-framework, -o <out>, -Wl,<flags>
#   . scripts/link.sh; link_exe <out> <objects and libraries...>
#
# build.sh sources it to link the seed, and names it as AUK_LINKER for what the seed builds: a
# seed from before 7d links with `cc` unless AUK_LINKER names another driver.
# $AUK_LINKER, when it names a real driver (cc, clang), is used instead (link_exe).
# Environment: SDKROOT, MACOSX_DEPLOYMENT_TARGET (macOS); LLVM_BIN or LLVM_CONFIG (Linux: where
# LLVM's ld.lld and llvm-readelf are).

link_die() { printf 'link: %s\n' "$*" >&2; exit 1; }

link_exe() {
  local out="$1"; shift
  if [ -n "${AUK_LINKER:-}" ] && [ "$(basename "$AUK_LINKER")" != link.sh ]; then
    case "$(uname -s)" in
      Darwin) "$AUK_LINKER" "$@" -lm -lpthread -Wl,-export_dynamic -o "$out" ;;
      *) "$AUK_LINKER" "$@" -lm -lpthread -rdynamic -o "$out" ;;
    esac
    return
  fi
  if [ "$(uname -s)" = Darwin ]; then
    # the SDK (libSystem's and the frameworks' stubs): $SDKROOT, the selected developer
    # directory's, the Command Line Tools', else xcrun's
    local sdk="${SDKROOT:-}" dev s sdkv min
    if [ -z "$sdk" ] || [ ! -d "$sdk" ]; then
      sdk=""
      for dev in "$(readlink /var/db/xcode_select_link 2> /dev/null || true)" /Library/Developer/CommandLineTools; do
        for s in Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk SDKs/MacOSX.sdk; do
          if [ -z "$sdk" ] && [ -n "$dev" ] && [ -d "$dev/$s" ]; then sdk="$dev/$s"; fi
        done
      done
    fi
    [ -n "$sdk" ] || sdk="$(xcrun --sdk macosx --show-sdk-path 2> /dev/null || true)"
    [ -n "$sdk" ] && [ -d "$sdk" ] ||
      link_die "linking needs the macOS SDK: install the Command Line Tools (xcode-select --install) or set SDKROOT"
    sdkv="$(grep -o '"Version" *: *"[^"]*"' "$sdk/SDKSettings.json" | head -1 | cut -d'"' -f4)"
    min="${MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | cut -d. -f1-2)}"
    ld -arch "$(uname -m)" -platform_version macos "$min" "${sdkv:-$min}" -syslibroot "$sdk" \
      -o "$out" "$@" -lSystem -export_dynamic
  else
    local bin="${LLVM_BIN:-$("${LLVM_CONFIG:-llvm-config-23}" --bindir 2> /dev/null || true)}"
    local multi interp d crt="" dirs=() linker
    case "$(uname -m)" in
      aarch64|arm64) multi=aarch64-linux-gnu interp=/lib/ld-linux-aarch64.so.1 ;;
      *) multi="$(uname -m)-linux-gnu" interp=/lib64/ld-linux-x86-64.so.2 ;;
    esac
    # glibc's path from the psABI (the same on every distribution), else the one /bin/sh names
    [ -e "$interp" ] ||
      interp="$("$bin/llvm-readelf" -l /bin/sh | sed -n 's/.*program interpreter: \(.*\)]$/\1/p')"
    for d in "/usr/lib/$multi" "/lib/$multi" /usr/lib64 /lib64 /usr/lib /lib; do
      [ -d "$d" ] || continue
      dirs+=("-L$d")
      if [ -z "$crt" ] && [ -f "$d/Scrt1.o" ]; then crt="$d"; fi
    done
    [ -n "$crt" ] ||
      link_die "linking needs the C library's start files (Scrt1.o): install libc6-dev (or glibc-devel)"
    if [ -n "$bin" ] && [ -x "$bin/ld.lld" ]; then linker="$bin/ld.lld"
    elif command -v ld.lld > /dev/null; then linker=ld.lld
    elif command -v ld > /dev/null; then linker=ld
    else link_die "no linker: install LLVM's lld (ld.lld) or binutils (ld), or set AUK_LINKER=cc"
    fi
    # compiler-rt's builtins (LLVM's, libclang-rt-23-dev), else libgcc: for code clang compiled,
    # which a seed cut before the runtime was all Auk still has (on AArch64 it calls libgcc's
    # outline atomics, `__aarch64_ldadd8_acq_rel`, ...). Code auk compiles needs neither.
    local rtlib=""
    local cpu="${multi%%-*}"
    for d in "$bin"/../lib/clang/*/lib/linux/libclang_rt.builtins-"$cpu".a \
      "$bin"/../lib/clang/*/lib/"$cpu"-*linux*/libclang_rt.builtins.a /usr/lib/gcc/"$multi"/*/libgcc.a; do
      if [ -z "$rtlib" ] && [ -f "$d" ]; then rtlib="$d"; fi
    done
    # GNU ld: GCC's crtbeginS.o/crtendS.o, which define __dso_handle (ld.lld defines it itself)
    local begin=() end=()
    case "$(basename "$linker")" in
      ld.lld*) ;;
      *)
        for d in /usr/lib/gcc/"$multi"/*/; do
          if [ -f "$d/crtbeginS.o" ] && [ -f "$d/crtendS.o" ]; then begin=("$d/crtbeginS.o") end=("$d/crtendS.o"); fi
        done
        [ ${#begin[@]} = 1 ] ||
          link_die "linking with GNU ld needs GCC's crtbeginS.o (libgcc's development files); or install LLVM's lld (ld.lld)" ;;
    esac
    "$linker" --eh-frame-hdr -pie -z relro -z now --export-dynamic -dynamic-linker "$interp" \
      -o "$out" "$crt/Scrt1.o" "$crt/crti.o" ${begin[@]+"${begin[@]}"} "${dirs[@]}" "$@" -lm -lc \
      ${rtlib:+"$rtlib"} ${end[@]+"${end[@]}"} "$crt/crtn.o"
  fi
}

# run as a driver: the cc-style arguments of `auk build` (and the seed's) to link_exe's
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  out="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out="$2"; shift ;;
      -rdynamic|-Wl,-export_dynamic) ;;  # link_exe exports the symbols
      -Wl,*) IFS=, read -r -a w <<< "${1#-Wl,}"; args+=("${w[@]}") ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  [ -n "$out" ] || link_die "no -o <output>"
  link_exe "$out" ${args[@]+"${args[@]}"}
fi
