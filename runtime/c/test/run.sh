#!/bin/sh
# Build and run the runtime's C unit tests (no cargo needed).
#
#   sh runtime/c/test/run.sh [name-filter]
#
# Every runtime/c/*.c file and the tests in runtime/c/test/ are compiled separately into a
# fresh build directory (never the source tree), linked, and run. Prints one `ok <name>` /
# `FAIL <name>` line per test and a summary; exits non-zero if anything fails to build or
# any test fails. The filter keeps only tests whose name contains it.
#
# ASAN=1 builds with AddressSanitizer and UBSan. CC overrides the compiler; by default it is
# Homebrew's clang (/opt/homebrew/opt/llvm@23/bin/clang) when present, else cc. Under ASAN=1
# the Homebrew clang is used only if it has the sanitizer runtimes; otherwise Apple's cc.
# TSAN=1 builds with ThreadSanitizer instead (the concurrency tests in test_conc.c are what it
# is for: `TSAN=1 sh runtime/c/test/run.sh conc`).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
rt=$(cd "$here/.." && pwd)
llvm_clang=/opt/homebrew/opt/llvm@23/bin/clang

build=$(mktemp -d "${TMPDIR:-/tmp}/auk_rt_tests.XXXXXX")
trap 'rm -rf "$build"' EXIT INT TERM

cflags="-std=c11 -O1 -g -I $rt"
case "$(uname -s)" in
Darwin)
    cflags="$cflags -fblocks"
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

echo "building with $CC${san:+ ($san)} in $build"
objs=""
for src in "$rt"/*.c; do
    obj="$build/rt_$(basename "$src" .c).o"
    $CC $cflags $san -c "$src" -o "$obj"
    objs="$objs $obj"
done
for src in "$here"/*.c; do
    obj="$build/test_$(basename "$src" .c).o"
    $CC $cflags $san -Wall -Wextra -Wno-unused-parameter -c "$src" -o "$obj"
    objs="$objs $obj"
done
$CC $san $objs $libs -o "$build/auk_rt_tests"

if [ "${TSAN:-0}" = 1 ]; then
    # Tests fork children that start threads (child(), the trace and debugger tests), and by
    # then the parent has threads of its own (Network.framework's, after the tls tests).
    # ThreadSanitizer refuses that unless told otherwise; the children only use what they
    # create themselves. A report makes the run fail (exit 66), in a child as in the parent.
    TSAN_OPTIONS=${TSAN_OPTIONS:-die_after_fork=0:halt_on_error=0:second_deadlock_stack=1}
    export TSAN_OPTIONS
elif [ -n "$san" ]; then
    # LeakSanitizer stays on (where the platform has it), minus leaks that are not the
    # runtime's: one-time caches of macOS's own frameworks (Network.framework, used by tls.c,
    # and what it pulls in), and the string immortal_and_leak_check makes immortal on purpose.
    # (Panics caught in forked children leak too, by design, but children _exit without a
    # leak check.) Undefined behaviour stops the program.
    cat > "$build/lsan.supp" <<'EOF'
leak:Network.framework
leak:CoreFoundation.framework
leak:Foundation.framework
leak:libxpc.dylib
leak:libswiftCore.dylib
leak:libobjc.A.dylib
leak:libsystem_info.dylib
leak:immortal_and_leak_check
EOF
    LSAN_OPTIONS=${LSAN_OPTIONS:-suppressions=$build/lsan.supp:print_suppressions=0}
    UBSAN_OPTIONS=${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}
    export LSAN_OPTIONS UBSAN_OPTIONS
fi

cd "$build"
"$build/auk_rt_tests" "$@"
