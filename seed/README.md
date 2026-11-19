# Bootstrap seed

`<os>-<arch>.bc.gz` is the Auk compiler as LLVM bitcode (the program and the runtime's
bitcode, linked), cut from the bootstrap fixed point by `scripts/cut_seed.sh`; `<os>-<arch>.txt`
names the commit it was cut from, its date, LLVM version and the sha256 of the bitcode.

`./build.sh` uses it when there is no `auk` to start from (or with `--from-seed`): clang
compiles it, `cc` links it with LLVM's library into `target/auk-build/seed/auk`, which builds
stage 1 and stage 2 from the sources. A fresh clone needs only LLVM 23 and a C linker.

A new seed is cut when the compiler can no longer be built by the current one (a language or
ABI change the seed doesn't know), and at every release. The tag `v0-rust-final` keeps the
last Rust compiler, which can rebuild a seed from scratch.

**The runtime's Auk half (Phase 7).** `build.sh` builds `runtime/src` (the `raw` dialect) with
the seed, before stage 1. A seed cut before the dialect (and the C-string literals it needs,
2026-11-19) can't, so build.sh first builds `compiler/` with it as "stage 0" and lets stage 0
build the runtime: such seeds keep working, one compiler build (~20 s) slower. Re-cut each
platform's seed to drop that step: `scripts/cut_seed.sh` on macOS arm64; Linux arm64 by
running it in the `ci/linux` image on a writable clone (`docker run --rm -v "$PWD:/src"
auk-linux bash -c 'git -c safe.directory="*" clone -q /src /work && cd /work && scripts/cut_seed.sh && cp seed/linux-*
/src/seed/'`); Linux x86-64 by the GitHub workflow `auk`, job
`seeds` (run by hand), which starts from the Rust `auk` of `v0-rust-final` and so goes through
stage 0 too.
