# Linux build and test image for the Auk compiler: Debian trixie, Rust stable (rustup), and
# LLVM 23 from apt.llvm.org (the back end links LLVM 23's C API through llvm-sys 231; the
# runtime is compiled with LLVM 23's clang). See ci/linux/test.sh and docs/compiler.md, Testing.
FROM debian:trixie

ARG LLVM=23
ENV DEBIAN_FRONTEND=noninteractive

# the toolchain, plus what the tests use: git (raft), python3 (scripts), OpenSSL (tls.c dlopens
# the library; a TLS test makes a certificate with the command), SQLite (FFI tests),
# zlib/zstd/libxml2/libffi (LLVM's link dependencies), lldb (the native debug info test)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg build-essential pkg-config git python3 \
        libssl3t64 libssl-dev openssl libsqlite3-dev zlib1g-dev libzstd-dev libxml2-dev libffi-dev \
        libedit-dev libncurses-dev \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/trixie/ llvm-toolchain-trixie-${LLVM} main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        llvm-${LLVM} llvm-${LLVM}-dev libllvm${LLVM} clang-${LLVM} libclang-rt-${LLVM}-dev lldb-${LLVM} \
    && rm -rf /var/lib/apt/lists/*

# llvm-sys finds LLVM here. It overrides .cargo/config.toml's Homebrew path: cargo's [env] does
# not replace a variable the environment already sets.
ENV LLVM_SYS_231_PREFIX=/usr/lib/llvm-${LLVM} \
    RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:/usr/lib/llvm-${LLVM}/bin:$PATH

RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
    && rustc --version

WORKDIR /src
