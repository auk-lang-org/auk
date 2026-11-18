#!/bin/sh
# The linker for `auk build` when the compiler was built with AUK_RT_SANITIZE=address: the
# runtime library embedded in it is instrumented, so programs link the sanitizer runtime too.
#
#   AUK_LINKER=runtime/c/test/asan-cc.sh auk build ...
#
# CC overrides the C compiler driver; by default Homebrew's LLVM clang, whose sanitizer runtime
# matches the clang that compiled the library.
cc=${CC:-/opt/homebrew/opt/llvm@23/bin/clang}
[ -x "$cc" ] || cc=cc
exec "$cc" -fsanitize=address,undefined "$@"
