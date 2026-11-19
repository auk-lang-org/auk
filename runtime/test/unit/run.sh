#!/bin/sh
# Build and run the runtime's unit tests (runtime/test/unit, Auk; the port of runtime/c/test).
#
#   sh runtime/test/unit/run.sh [name-filter]
#
# The tests are modules of the runtime package itself (the `raw` dialect is only for the
# package named `auk_rt`): a fresh build directory gets runtime/raft.toml and a src/ holding
# runtime/src/*.auk and runtime/test/unit/*.auk, and `auk build --lib` compiles the runtime and
# the tests into one object, whose `export fn main` (ut_main.auk) is the program's entry; cc
# links it (with any C file still in runtime/c) into auk_rt_tests. Each test runs in a forked
# child; the program prints one `ok <name>` / `FAIL <name>` line per test and a summary, and
# exits non-zero if anything fails to build or any test fails. The filter keeps only tests
# whose name contains it.
#
# AUK is the auk that builds them: by default the checkout's target/bin/auk (build.sh), else
# `auk` on the PATH.
#
# ASAN=1 instruments everything with AddressSanitizer: the bitcode of the runtime and the tests
# (`auk build --lib --bc`, every function given `sanitize_address`, LLVM's `asan` pass with
# `opt`, then clang -c), and the C files with -fsanitize=address,undefined. LeakSanitizer (where
# the platform has it) checks each test's child process when the test ends. TSAN=1 does the
# same with ThreadSanitizer (`tsan-module,function(tsan)`), for the concurrency tests above all
# (`TSAN=1 sh runtime/test/unit/run.sh conc`). CC overrides the C compiler and linker; by default
# Homebrew's LLVM clang (/opt/homebrew/opt/llvm@23/bin/clang) when present and able to link the
# sanitizer's runtime, else cc. LLVM_BIN overrides where opt, llvm-dis and clang are taken from
# for the instrumented build (by default the directory of CC, else Homebrew's LLVM, else
# llvm-config-23's).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
rt=$(cd "$here/../.." && pwd)   # runtime/
llvm_clang=/opt/homebrew/opt/llvm@23/bin/clang

build=$(mktemp -d "${TMPDIR:-/tmp}/auk_rt_unit.XXXXXX")
trap 'rm -rf "$build"' EXIT INT TERM

cflags="-std=c11 -O1 -g -I $rt/c"
case "$(uname -s)" in
Darwin)
    cflags="$cflags -fno-blocks"
    libs="-framework Network -framework Security -framework CoreFoundation"
    ;;
*)
    # glibc hides POSIX/BSD declarations under plain -std=c11
    cflags="$cflags -D_GNU_SOURCE"
    libs="-ldl -lpthread -lm"
    ;;
esac

san=""
if [ "${ASAN:-0}" = 1 ] && [ "${TSAN:-0}" = 1 ]; then
    echo "ASAN=1 and TSAN=1 can't be combined" >&2
    exit 2
fi
if [ "${ASAN:-0}" = 1 ]; then
    san="-fsanitize=address,undefined -fno-omit-frame-pointer"
elif [ "${TSAN:-0}" = 1 ]; then
    san="-fsanitize=thread -fno-omit-frame-pointer"
fi

# Pick the compiler: does $1 build and link a program with the sanitizer flags?
can_sanitize() {
    printf 'int main(void) { return 0; }\n' > "$build/probe.c"
    "$1" $san "$build/probe.c" -o "$build/probe" > /dev/null 2>&1
}
if [ -z "${CC:-}" ]; then
    CC=cc
    if [ -x "$llvm_clang" ]; then
        if [ -z "$san" ] || can_sanitize "$llvm_clang"; then
            CC=$llvm_clang
        fi
    fi
fi

auk=${AUK:-$rt/../target/bin/auk}
[ -x "$auk" ] || auk=$(command -v auk || true)
[ -n "$auk" ] || { echo "run.sh: no auk to build the tests with (run ./build.sh, or set AUK)" >&2; exit 1; }

# The package: the runtime's modules and the tests' (which must not share a name).
mkdir -p "$build/pkg/src"
cp "$rt/raft.toml" "$build/pkg/"
cp "$rt"/src/*.auk "$build/pkg/src/"
for f in "$here"/*.auk; do
    if [ -e "$build/pkg/src/$(basename "$f")" ]; then
        echo "run.sh: runtime/test/unit/$(basename "$f") has the name of a runtime module" >&2
        exit 1
    fi
    cp "$f" "$build/pkg/src/"
done

echo "building with $auk${san:+ ($san, the Auk code instrumented too)} in $build"
if [ -n "$san" ]; then
    # Everything Auk instrumented: its bitcode, every function marked for the sanitizer, run
    # through LLVM's pass (tsan, or asan: memory and atomics), compiled by clang.
    llvm_bin=${LLVM_BIN:-$(dirname "$CC")}
    [ -x "$llvm_bin/opt" ] || llvm_bin=/opt/homebrew/opt/llvm@23/bin
    [ -x "$llvm_bin/opt" ] || llvm_bin=$(llvm-config-23 --bindir 2>/dev/null || true)
    [ -x "$llvm_bin/opt" ] || { echo "run.sh: no LLVM opt for the instrumented build (set LLVM_BIN)" >&2; exit 1; }
    case "$san" in
    *thread*) attr=sanitize_thread passes='tsan-module,function(tsan)' ;;
    *) attr=sanitize_address passes=asan ;;
    esac
    "$auk" build --lib --bc "$build/pkg/src/lib.auk" -o "$build/unit.bc"
    "$llvm_bin/llvm-dis" "$build/unit.bc" -o "$build/unit.ll"
    sed -E "s/^(attributes #[0-9]+ = \{)/\1 $attr /" "$build/unit.ll" > "$build/unit_san.ll"
    "$llvm_bin/opt" -passes="$passes" "$build/unit_san.ll" -o "$build/unit_san.bc"
    "$llvm_bin/clang" -c -O1 -Wno-override-module "$build/unit_san.bc" -o "$build/unit.o"
else
    "$auk" build --lib "$build/pkg/src/lib.auk" -o "$build/unit.o"
fi
objs="$build/unit.o"
# any C left in runtime/c (none since Phase 7c: the glob finds nothing)
for src in "$rt"/c/*.c; do
    [ -e "$src" ] || continue
    obj="$build/c_$(basename "$src" .c).o"
    $CC $cflags $san -c "$src" -o "$obj"
    objs="$objs $obj"
done
$CC $san $objs $libs -o "$build/auk_rt_tests"

if [ "${TSAN:-0}" = 1 ]; then
    # Tests fork children that start threads (child(), the trace and debugger tests), after
    # threads of their own. ThreadSanitizer refuses that unless told otherwise; the children
    # only use what they create themselves. A report fails the test whose output has it.
    TSAN_OPTIONS=${TSAN_OPTIONS:-die_after_fork=0:halt_on_error=0:second_deadlock_stack=1}
    export TSAN_OPTIONS
elif [ -n "$san" ]; then
    # LeakSanitizer checks each test's child when the test ends (on macOS too: its default is
    # off), minus leaks that are not the runtime's: one-time caches of macOS's own libraries
    # (Network.framework and BoringSSL, used by the TLS module, and what they pull in; dyld's
    # thread-locals; libSystem's fork handlers) and the string immortal_and_leak_check makes
    # immortal on purpose. (Panics in forked children leak, by design, but those children
    # _exit without a leak check.) Undefined behaviour in the C stops the program.
    cat > "$build/lsan.supp" <<'EOF'
leak:Network.framework
leak:CoreFoundation.framework
leak:Foundation.framework
leak:libxpc.dylib
leak:libswiftCore.dylib
leak:libobjc.A.dylib
leak:libsystem_info.dylib
leak:libsystem_notify.dylib
leak:libboringssl.dylib
leak:libdyld.dylib
leak:immortal_and_leak_check
EOF
    ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=1}
    LSAN_OPTIONS=${LSAN_OPTIONS:-suppressions=$build/lsan.supp:print_suppressions=0}
    UBSAN_OPTIONS=${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}
    export ASAN_OPTIONS LSAN_OPTIONS UBSAN_OPTIONS
fi

cd "$build"
"$build/auk_rt_tests" "$@"
