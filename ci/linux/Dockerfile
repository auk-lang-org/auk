# Linux build and test image for the Auk compiler: Debian trixie and LLVM 23 from apt.llvm.org
# (the compiler links LLVM 23's C API through the `llvm` package and compiles the seed with its
# llc; executables are linked by LLVM's ld.lld with glibc's start files: libc6-dev). No C
# compiler is needed to build Auk, only to test its C interop (TEST_CC below). See
# ci/linux/test.sh and docs/compiler.md, Testing.
FROM debian:trixie

ARG LLVM=23
# The C compiler the tests of C interop use as `cc` (the FFI and raw suites' C libraries and
# mains, the ABI probe, the llvm package's example): gcc, or empty for an image that builds Auk
# with no `cc` at all (`ci/linux/test.sh --no-cc`).
ARG TEST_CC=gcc
ENV DEBIAN_FRONTEND=noninteractive

# the toolchain, plus what the tests use: git (raft), python3 (scripts), OpenSSL (tls dlopens
# the library; a TLS test makes a certificate with the command), SQLite (FFI tests),
# zlib/zstd/libxml2/libffi (LLVM's link dependencies), lldb (the native debug info test),
# compiler-rt (libclang-rt: its builtins for the seed's code clang compiled, the sanitizer
# runtimes of the unit tests' ASAN=1/TSAN=1 builds).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg libc6-dev pkg-config git python3 ${TEST_CC} \
        libssl3t64 libssl-dev openssl libsqlite3-dev zlib1g-dev libzstd-dev libxml2-dev libffi-dev \
        libedit-dev libncurses-dev \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/trixie/ llvm-toolchain-trixie-${LLVM} main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        llvm-${LLVM} llvm-${LLVM}-dev libllvm${LLVM} lld-${LLVM} libclang-rt-${LLVM}-dev lldb-${LLVM} \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/lib/llvm-${LLVM}/bin:$PATH

WORKDIR /src
