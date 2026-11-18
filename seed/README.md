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
