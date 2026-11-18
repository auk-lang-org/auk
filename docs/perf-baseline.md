# Perf baseline

The numbers every phase of [the self-hosting plan](self-host-plan.md) compares against (Phase 0).
Written by `scripts/baseline.sh`; rerun it on a quiet machine to refresh, and keep older tables
below when a phase changes them.

- **Date:** 2026-11-18
- **Commit:** efbd821
- **Machine:** Apple M5, 10 cores, 24 GB, macOS 27.2.1 arm64
- **Toolchain:** rustc 1.99.1, LLVM 23.1.4, `cargo build --release`
- **Load average when it started:** 28.45 (a busy machine inflates every number)
- **Method:** best of 5 runs (corpus-wide rows: best of 2), wall time

## Generated code: bench/perf

`bench/perf/run.sh` (see [bench/perf/README.md](../bench/perf/README.md)): the same seven
programs in Auk (`auk build`) and Rust (`-C opt-level=3 -C target-cpu=native`).

| bench | size | rust -O | rust +overflow | auk | auk/rust | auk/rust+oc | output match |
|---|---|---|---|---|---|---|---|
| fib | 38 | 0.099s | 0.134s | 0.155s | **1.57x** | 1.16x | yes |
| sieve | 50,000,000 | 0.237s | 0.250s | 0.462s | **1.95x** | 1.85x | yes |
| nbody | 5,000,000 | 0.352s | 0.263s | 0.725s | **2.06x** | 2.76x | yes |
| hashmap | 5,000,000 | 0.289s | 0.237s | 0.468s | **1.62x** | 1.98x | yes |
| trees | 18 | 3.409s | 3.441s | 5.003s | **1.47x** | 1.45x | yes |
| strings | 5,000,000 | 0.420s | 0.467s | 1.179s | **2.80x** | 2.52x | yes |
| sort | 10,000,000 | 0.287s | 0.311s | 0.228s | **0.79x** | 0.73x | yes |

## Compiler

| what | time | note |
|---|---|---|
| `auk check` of every corpus file (239 files, 1,085,105 bytes), one process each | 12,041 ms |  |
| `auk dump ast` of every corpus file, one process each | 6,552 ms |  |
| `auk ir` (MIR) of the 21 programs that check clean | 7,625 ms |  |
| `auk build hello.auk` | 137 ms | examples/ copy, outside a project |
| `auk build tour.auk` | 374 ms | examples/ copy, outside a project |
| `auk build life.auk` | 254 ms | examples/ copy, outside a project |
| `auk build compiler/src/main.auk` | 3,930 ms | the pilot front end, 4.5k lines |
| `auk build examples/hello.auk` | 52,269 ms | in the examples project: compiles all of http, json, audio, graphics (one run) |
| `auk run hello.auk` (startup to exit) | 33 ms | outside a project |
| `auk run examples/hello.auk` | 2,337 ms | in the examples project (one run) |
| `auk run -O hello.auk` | 40 ms | outside a project |
| `auk run compiler/src/main.auk ast examples/tour.auk` | 761 ms | JIT-compile the pilot, then parse |
