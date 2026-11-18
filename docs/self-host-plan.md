# Plan: Auk only — from Rust, through C, to a self-hosted Auk

**End state:** Auk is written in Auk. Building it needs only an `auk` binary (or the checked-in
bootstrap seed) and LLVM — no Rust, no C compiler. The only non-Auk code left is the OS
(libc/libSystem, system frameworks) and LLVM's own libraries.

**Route:** Rust → C runtime + Auk compiler (Phases 1–6) → Auk runtime (Phase 7). C is a
stepping stone: it gets Rust out without waiting for the low-level language features an Auk
runtime needs. (C over C++: setjmp-based `catch` makes RAII unsafe.)

**Rule for every phase:** one moving part at a time. After every step there is a working
`auk`, and the whole suite is green. Nothing merges that breaks that.

What there is to move today:

| Part | Where | Size |
|---|---|---|
| Runtime | `runtime/c/*.c` + `auk_rt.h` (was `runtime/src/*.rs`) | ~14k lines C, 21 files (Phase 1 done) |
| Runtime tests | `runtime/tests/*.rs` | ~2.7k lines |
| Compiler | `src/` (lexer → check → MIR → LLVM) | ~37k lines Rust |
| Tools | `fmt repl lsp dap debug mcp live hatch explain dive`, `raft` | inside the 37k |
| Integration tests | `tests/*.rs` (24 files) + fixtures | drive the binaries |
| Build | `Cargo.toml`, `build.rs`, `runtime/build.rs`, `.cargo/config.toml` | |
| Rust deps | `llvm-sys`, `libc`, `cc` (rustls and webpki-roots went with Phase 1) | |
| Auk code already | `src/prelude/*.auk`, `packages/` (24), `examples/` | 135 `.auk` files under tests/examples/packages |

---

## Phase 0 — Groundwork

- [x] **Perf baseline:** record `bench/perf` numbers and compile times (whole corpus: `auk check`,
      `auk build`, `auk run` startup) on the current Rust build. Every later phase compares to these.
      `scripts/baseline.sh` → [perf-baseline.md](perf-baseline.md).
- [x] **Golden corpus:** a script that runs the Rust `auk` over every `.auk` in `tests/`,
      `examples/`, `packages/`, `src/prelude/` and saves: token dump, diagnostics (JSON),
      `auk ir` MIR text, `auk fmt` output, program stdout/stderr/exit code. Phases 3–5 diff against it.
      `scripts/golden.sh` (docs/compiler.md, Testing): 239 files (with `compiler/`) × tokens, ast,
      check, fmt; MIR of the 21 programs that check clean; 46 runs (`auk run` of 19 programs and
      argument/stdin cases, `auk test` of every package and the examples, from
      `scripts/golden_runs.txt`). `--compare <auk>` diffs another build per mode and file.
      The Rust `auk` against itself: 0 differences after one fix (a "did you mean" picked in
      `HashMap` order). MIR is 94 MB of the 113 MB: every program's MIR includes the whole prelude
      and, in a project, every dependency.
- [x] Add the dump modes the golden corpus needs if missing (`auk tokens`, stable AST dump):
      `auk dump tokens|ast` (hidden, `src/dump.rs`; added by the 2e pilot).
- [x] CI job (or `make check`) that runs: cargo tests, `tests/*.rs`, runtime tests, bench smoke.
      `scripts/check.sh`: those plus the pilot diffs and golden self-consistency.
- [ ] Decide versioning for the transition: the Rust `auk` is "stage 0" and is tagged
      (`v0-rust-final`) at the end of Phase 4 so it can always rebuild the seed.

## Phase 1 — Runtime to C (Rust compiler unchanged)

C lives in `runtime/c/`, one header `auk_rt.h` (the layouts generated code relies on; `AUK_API`
marks every entry point it calls). **Status:** all modules ported (commits c44691e..c1221ca, one
per module, suite green after each) and the `auk_rt` crate removed; tests and sanitizers below.

### 1a. Build plumbing
- [x] `runtime/build.rs`: compile `runtime/c/*.c` with the `cc` crate and link them into `auk_rt`
      while Rust and C modules coexist. Compiled as **one translation unit** (a file including
      every source) so cross-file calls inline; files including system framework headers are
      marked `auk: own translation unit` and compile alone. `-fno-stack-protector`.
- [x] Root `build.rs`: the nested `cargo rustc` is gone; the cc crate (with the back end's clang)
      builds `libauk_rt.a`, and `clang -emit-llvm` + `llvm-link` build `auk_rt.bc`.
- [x] Generate `rt_symbols.rs` (the JIT's symbol table) from `auk_rt.h` (`AUK_API` lines).
- [ ] A check that `auk_rt.h` matches the layouts the compiler assumes (`src/mir/layout.rs`):
      `_Static_assert` on sizes/offsets in C, and a test that compares them to the compiler's.

### 1b. Replacements for Rust std (shared C helpers)
- [x] Locks/threads: `pthread_mutex`, `pthread_cond`, `pthread_create`; `_Thread_local` for
      `thread_local!`/`Cell`; C11 `<stdatomic.h>` for atomics and `Arc`-style counts.
- [x] A growable byte buffer and message building without varargs: messages are built in an
      `AukStrBuf` (`auk__sb_put`, `auk_sb_int`, then `auk__panic_sb` / `auk__err_sb`).
- [x] Panics → one `auk__panic(loc, msg, n)` (and `auk__panic3`), same text as before.
- [x] UTF-8 encode/decode helpers (`.chars()`, char boundaries) for `str` and `rc`.
- [x] Float formatting: no Ryu needed — binary search for the smallest `%.*e` precision that
      round-trips gives the same output (checked identical on 480k values).
- [x] Float parsing: `strtod` with the same rejections as before (the runtime already used it).
- [x] Unicode tables: not needed (the runtime's case and class functions are ASCII-only).
- [x] Time (`clock_gettime`), env (`getenv`/`environ`), process (`posix_spawn`, pipes,
      `waitpid`), fs (POSIX), sockets (BSD), error text (`strerror`).

### 1c. Port modules, leaf first (suite after each)
Each: write the C, delete the `.rs`, run runtime tests + full suite, compare perf.
- [x] `value`, `err`, `copy`, `heap`, `rc`
- [x] `catch`: folded into C entirely; setjmp/longjmp only in `catch.c`
- [x] `str`, `arr` (int sort: LSD radix over the varying bits, faster than Rust's), `map`
- [x] `chan`, `task`
- [x] `core`: fs, net, proc, time, env, rand
- [x] `tls`: **Network.framework** on macOS; **OpenSSL via dlopen** elsewhere. Verification
      always on, same error messages (checked against badssl.com). Drops `rustls`, `ring`,
      `webpki-roots`.
- [x] `trace`, `dbg` (the compiler's eval hook through a C interface, `src/rt.rs`), `testing`,
      `compiler`
- [x] `pixels`, `audio_out` — no `.m`: AudioToolbox via `dlopen`, as before
- [x] `gui`, `gui_host` — no `.m`: AppKit via `dlopen` and `objc_msgSend` through exactly-typed
      pointers, as before
- [x] `lib.rs`: gone with the crate; the compiler's few runtime adapters live in `src/rt.rs`

**Write C that will translate to Auk later (Phase 7):** plain functions and structs; no
macro-generated code; no varargs in the runtime's own API; no bit-fields; nothing beyond
libc/pthreads/system frameworks; setjmp/longjmp only in `catch.c`; no Objective-C sources (the
runtime calls `objc_msgSend` from C).

### 1d. Tests and safety
- [x] Port `runtime/tests/*.rs` (62 tests) to C in `runtime/c/test/`: `sh runtime/c/test/run.sh
      [filter]`, `ASAN=1` for AddressSanitizer + UBSan (clean; LeakSanitizer stays on, with
      suppressions only for one-time allocations inside macOS frameworks).
- [x] TLS on Network.framework: badssl.com reset about half the connections before sending a
      certificate. Cause: Network.framework's 1.5 KB TLS 1.3 hello with an X25519MLKEM768 key
      share (two TCP segments); OpenSSL offering that group gets the same resets, X25519 alone
      none, so it is the server side. A reset before the certificate is now retried once as a
      TLS 1.2 hello with TLS_FALLBACK_SCSV (no downgrade of a TLS 1.3 server); 30/30 certificate
      errors since.
- [x] ASan + UBSan build of the runtime tests (above).
- [x] TSan: `TSAN=1 sh runtime/c/test/run.sh`, with concurrency stress tests
      (`runtime/c/test/test_conc.c`: tasks, cancel and links, heaps swept on other threads,
      channels, shared handle refcounts, the trace and debugger locks). Clean, no
      suppressions. Found and fixed: a use after free in `heap` sweep (a container freed after
      the objects it held), and in `dbg` a race between the all-stop inspector and threads
      returning from blocking calls (frame chains changed under it), a `pause` lost behind a
      queued `continue`, SIGPIPE when the front end hung up, and a stop at a breakpoint
      deleted while the thread waited.
- [x] The whole suite under ASan: `AUK_RT_SANITIZE=address` (docs/compiler.md, Testing).
      `cargo test --release` and `auk test` over packages/ and examples: no reports.
- [x] Linux build and test: `ci/linux/test.sh` (Docker, Debian trixie arm64, LLVM 23 from
      apt.llvm.org; docs/compiler.md, Testing). The whole `cargo test --release` suite passes.
      Fixes: `-D_GNU_SOURCE` for the runtime under glibc, plain `char` is unsigned on Linux
      arm64 (FFI messages now say `char`), `[link] macos`/`linux` for per-OS libraries (the
      `llvm` package links `-lLLVM-23` on Linux), and `auk build -g` checked with lldb and
      `llvm-dwarfdump` on Linux too. x86-64 Linux is untested so far
      (`AUK_LINUX_PLATFORM=linux/amd64`, emulated).

**Done when:** `runtime/` has no `.rs`; rustls/ring/webpki-roots/`cc`-for-catch gone; all tests
pass on macOS and Linux; ASan clean; `bench/perf` within ±5% of Phase 0.

## Phase 2 — FFI and the LLVM binding

### 2a. User-level FFI (`docs/ffi-plan.md`)
- [x] `extern fn ... = "<C prototype>"` allowed in packages declaring `effects = ["ffi"]`.
- [x] C prototype parser, Auk↔C type check (E0040), marshalling (ints, bool, float, `str` ↔
      `const char *`, `ffi.Ptr`, `void`).
- [x] JIT resolves user symbols (dlopen/dlsym); `auk build` links named libraries.

### 2b. What the compiler-in-Auk additionally needs
- [x] Opaque pointer types per C type (`LLVMValueRef`, `LLVMTypeRef`, …) so they don't mix:
      `extern type Value = "LLVMValueRef"`.
- [x] Arrays of pointers passed in (`LLVMTypeRef *params, unsigned n`): a `[Type]` argument
      (copied to a C array for the call; `var [Type]` copies back, for `LLVMGetParams`).
- [x] Out-parameters (`char **err`, `LLVMModuleRef *out`): `var str?`, `var Module?`.
- [x] Owned C strings returned (`LLVMPrintModuleToString` → copy → `LLVMDisposeMessage`):
      `"char *LLVMPrintModuleToString(LLVMModuleRef) +free(LLVMDisposeMessage)"`.
- [x] Byte buffers in/out (`LLVMMemoryBufferRef` for object files and bitcode): `[int]` ↔
      `const char *`/`void *` in, `ffi.bytes(LLVMGetBufferStart(b), LLVMGetBufferSize(b))` out.
- [ ] Callbacks: not needed. ORC's symbol lookups and LLVM's diagnostic handler have defaults the
      Rust back end already relies on (it installs no handler; errors come back as `char **` /
      `LLVMErrorRef`). Deferred until something requires one.

### 2c. `llvm` binding package
- [x] Bind the LLVM C functions `src/mir/llvm/` and `src/build.rs` use, generated from a list
      (`packages/llvm/gen/gen.py` over `gen/bind.txt` and the LLVM 23 headers; `--check` finds
      names `src/` uses that the list lacks): 211 functions in `llvm.ir` (40), `values` (54),
      `builder` (56), `debug` (10), `target` (24), `orc` (16), `bitcode` (8), `passes` (3); 21
      `extern type`s, one per `LLVM*Ref`; 57 enum constants. Of the 262 names `src/` uses, only
      the ORC structs `LLVMOrcCSymbolMapPair`/`LLVMJITEvaluatedSymbol`/`LLVMJITSymbolFlags` aren't
      bound as such (by value in an array): `llvm.kit.define` lays them out with `ffi.alloc`.
      `--survey`: 1062 of the C API's 1066 functions bind; the rest take `const char **` or
      MCJIT's options struct.
- [x] FFI extension: `"T (*)(params)"` prototypes call a C function by address (`Callee::CPtr`),
      which is how Auk calls code ORC compiled.
- [x] Proof (`auk test packages/llvm`, leak-checked, and `tests/llvm_package.rs`): `add(i64, i64)`
      built in Auk, verified, IR compared as text, JIT-compiled with ORC LLJIT and called through
      the looked-up address; object file, assembly and bitcode emitted, bitcode read back and
      linked into another module; O2 run; debug info; absolute symbols. `packages/llvm/example`
      also links the object with `cc` into an executable (`auk run` and `auk build`).
- [x] Port one small piece of codegen: `Gen::bin`, `truth`, `bool8`, `cstr_addr` from
      `codegen.rs` (`llvm.codegen`), each operator JIT-compiled and called.

Gaps for Phase 4, found doing 2c:
- [x] No conversion between an `extern type` and `ffi.Ptr`. Done as a cast prototype, no call:
      `extern fn value_ptr(v: Value): ffi.Ptr = "(void *)"`, `extern fn value_at(p: ffi.Ptr):
      Value = "(LLVMValueRef)"` (`T?` ↔ NULL too). `llvm.kit.define` uses one instead of a second
      binding of `LLVMOrcLLJITMangleAndIntern` returning `void *`.
- [x] `rt_symbols()`: the JIT defines the runtime's addresses as absolute symbols. The Auk
      compiler needs those addresses in its own process. Done both ways: `auk build` links with
      `-export_dynamic` (macOS) / `-rdynamic` (Linux), so ORC's process generator finds the
      runtime, and `ffi.symbol(name): ffi.Ptr?` is `dlsym(RTLD_DEFAULT, name)` for an explicit
      table (`llvm.kit.define`). Tested by an `auk build` program calling `auk_str_from_bytes`,
      `auk_str_len` and `auk_release` by address (`tests/ffi.rs`).
- [x] Embedding files in the binary: `rtlink.rs` and `build.rs` `include_bytes!` `auk_rt.bc` and
      `libauk_rt.a`. Done as an FFI prototype (C23's `#embed`; `imprint` is pure, so it can't
      read files): `extern fn rt_bc(): ffi.Ptr = "#embed auk_rt.bc"` and
      `extern fn rt_bc_len(): int = "#embed auk_rt.bc"` (no copy; hand them to
      `LLVMCreateMemoryBufferWithMemoryRange`), or `: [int]` / `: str` (the prelude's sources)
      for a copy. The path is relative to the source file, so the build that makes the compiler
      must put `auk_rt.bc` and `libauk_rt.a` where `compiler/` expects them first.
- [x] `[link] libs` can't ask `llvm-config`. Done: `[link]` entries expand `${VAR}`,
      `${VAR:-default}` and `$(tool args)` when a program runs or is built; packages/llvm has
      `macos = ["$(${LLVM_CONFIG:-/opt/homebrew/opt/llvm@23/bin/llvm-config} --libdir)/libLLVM.dylib"]`
      and `linux = ["$(${LLVM_CONFIG:-llvm-config-23} --libdir)/libLLVM.so"]`.
- [x] A string's byte length costs a copy (`s.bytes().len()`); every generated wrapper for a
      `const char *` + length pays it. Done: `s.byte_len()` (the runtime's stored length), used
      by the generated wrappers.
- [ ] Each call that takes a list (`build_call2`, `build_gep2`, `function_type`) mallocs and frees
      a C array; fine for the pilot, measure in Phase 4.
- [ ] Which `LLVM*Ref` parameters accept NULL and which results may be NULL is a hand list in
      `gen.py` (`NULLABLE_ARG`, `NULLABLE_RET`); porting the rest of the back end will add to it,
      and to `bind.txt` for new functions and enum values.
- [ ] One `extern fn` per JIT entry signature (`"int64_t (*)(int64_t, int64_t)"`); `exec.rs`'s
      few fixed entry points (`dk_entry`, `dk_init`) fit that.

### 2d. Language/runtime gaps the compiler will hit (fix before Phase 3)
- [x] In-place mutation of uniquely owned arrays/maps (no copy when rc == 1) — the compiler is
      all vectors and maps. Measured by the pilot: `h.xs.push(x)` through a `var` parameter,
      `xs[i].push(x)` and `m[k].push(x)` are O(1). Still missing: moving a value *out* of a
      container (take, change, put back copies; see below).
- [x] Efficient string building (append without O(n²)). The pilot measured `s += "x"` as
      quadratic (80k appends: 202 ms, 20k: 6 ms; `[str]` + `join`: 3 ms). Now in place when
      the string is unique: 80k appends in 2 ms.
- [ ] Anything else the pilot exposes: big recursive enums (AST/MIR), deep recursion limits,
      hash maps keyed by structs/ints, sorting with a comparator, interning.
      Found by the pilot (details and snippets in [pilot-report.md](pilot-report.md), "Gaps"):
  - [x] `var` parameters in function types (`(var P) => T`), for parser combinators.
  - [x] Or-patterns (`A | B =>`).
  - [x] Bare variant names of another module's enum in expressions where `T?`/`T!`/`T!E` is
        expected (and never silently core's `Value.Float`/`Int`/`Str`: E0117), or a way to import them.
  - [x] Moving a value out of a list/map element (no copy when it goes back): `var g = xs[i]`
        … `xs[i] = g` moves (80k: 870 ms → 2 ms); no new syntax.
  - [x] Reads without RC: a value read from a container/parameter that isn't mutated while it
        lives is borrowed (no retain/release); no RC for payload-less enum constants.
  - [ ] One allocation per AST node: box the recursive edge or the variant payload, not both.
        Tried (box only the enum's fields, keep the enum inline in the struct): trees 2.5x
        faster, but the Auk parser 9–11% slower (an inline `ExprKind` makes every `Expr` copy
        big); needs boxing the variant payload as one cell. Not done (pilot-report.md).
  - [x] `match` on `str` dispatches on length/first byte instead of a chain of `auk_str_eq`
        (a sorted table, binary search by length then bytes: 20 arms 3x faster).
  - [x] `str([char])` builds straight into one buffer; `str(cs[a..b])` skips the slice (4x).
  - [x] Stack: deep recursion (Auk parser: 359 nested parens vs Rust's 925; now over 10000 on a
        256 MB main stack) and a "stack overflow" panic instead of a bare SIGSEGV.
  - [x] Smaller: `trim_start`/`trim_end`, `strip_prefix`/`strip_suffix`, `int.parse(s, radix)`,
        `c.is_digit(radix)`, `min(a, b)`/`max(a, b)`, `{n:x}`/`X`/`o`/`b`, tuple assignment.
  - [ ] Deferred (see pilot-report.md, "Gaps"): raw identifiers or keyword field names, `T!E` with
        a struct `E`, unsigned/narrow ints, `T??`, Unicode char classes (1b).
- [ ] Process/fs/args/env APIs the driver needs (`auk build` writes temp files, runs the linker,
      `dsymutil`).

### 2e. Pilot — go/no-go
- [x] Port `token.rs` (268) + `lexer.rs` (1077) + `ast.rs` (794) + `parser.rs` (2143) to Auk.
      `compiler/src/` (with the unit parser of `units.rs`); see [pilot-report.md](pilot-report.md).
- [x] Byte-identical token and AST dumps over the golden corpus (`scripts/diff_tokens.sh`,
      `scripts/diff_ast.sh`: 0 differences in 221 files, lexer and parser errors included).
- [x] Time both on the whole corpus. **Go** if the Auk version is within ~2–3× of Rust (and
      profiling shows a path to closer); otherwise fix codegen/runtime first and re-measure.
      Result: **go** (`scripts/pilot_time.sh`; numbers and profile in the report).

## Phase 3 — Self-hosted front end (language freeze starts)

Auk compiler lives in `compiler/`, built by the Rust `auk` (stage 0). Pipeline order, each
step diffed against the golden corpus before the next starts:

- [ ] Shared: `diag.rs` (385) diagnostics + fix-its, `json.rs` (434), `types.rs` (554).
      `types.rs` done (3a): `compiler/src/types.auk`. `diag.rs` so far only `Span`/`Diag`/`Fix`
      and `FileDiag`; rendering (`render`, the code table) and `json.rs` come with the checker's
      diagnostics gate.
- [x] `resolve.rs` (578): `compiler/src/resolve.auk` (3a). Oracle `auk dump resolve <file>`
      (`src/dump.rs`, unit test `dump::tests::resolve_dump`): load as `auk check` does
      (`load_in_package`), print packages (deps, effects, links), modules in load order with
      their children, each non-core module's items with full paths, and every module path a
      module mentions (`Program::first_segment`, then `child`) with the module it reaches; or the
      load diagnostics. `scripts/diff_resolve.sh`: **254 files, 0 differ** (E0100 missing
      dependencies, E0101 collisions and parse errors in submodules included;
      `compiler/tests/resolve/` adds two projects with installed `.raft/` deps, folder modules,
      a file and a folder of the same name, and `[link]` per OS). Timing: see pilot-report.md,
      "Phase 3".

  **What the checker port (3b) builds on** (all in `compiler/src/`, same names as Rust):
  - `types.auk`: `Ty` (a recursive enum; ids are `int`s: `Named(d, args)`, `Param(p)`, `Any(s)`,
    `Var(v)`; a unit is its canonical `[(str, int)]`), `TypeDef`/`TypeDefKind`/`FieldDef`/
    `VariantDef`/`ShapeDef`/`ShapeMethod`/`Builtin`/`TypeParam`, `Defs { types, shapes, params }`
    with `fields`, `variants`, `is_enum`, `subst_of`, `show`, `is_err`; `Infer { vars, trail }`
    with `fresh`/`snapshot`/`rollback`/`shallow`/`resolve`/`unify`/`try_unify`/`can_unify`, all
    taking `var Infer`. Rust's `walk(|t| yes |= ..)` is `any_ty(t, pred)`; `Ty::units()` is
    `units_of` (a fn named like the `units` module would read as a path).
  - `units.auk`: `combine`, `pow`, `root`, `exponent_hint`, `text` (Display) next to `parse`.
  - `resolve.auk`: `Program { pkgs, mods, root, focus, core_pkg, core_root }`, `Module { pkg,
    path, file, src, ast, children }`, `Package`, `first_segment`/`child`/`name`/`is_core`,
    `load`/`load_source`/`load_in_package`/`source_of`, `parse_manifest`. Everything that reads
    files takes a `Sources` (prelude texts, `with_sources` overrides, the OS): the prelude is read
    from `src/prelude/` at start-up (`$AUK_PRELUDE_DIR`, or found upward from the binary) because
    Auk can't embed files; see the gap below. Rust's `BTreeMap` iteration is `sorted_keys(m)`.
  - `visit.auk`: `visit_item_exprs`/`visit_expr` (check.rs) push every expression, pre-order,
    onto a `var [ast.Expr]`; `as_path` (check/expr.rs).
  - `paths.auk`: `std::path` on `str` (`join`, `parent`, `file_stem`, `extension`, component
    order, `is_under`/`strip_base`), `canonicalize`/`cwd` (C `realpath`) and `os` (C `uname`), so
    `compiler/` declares `effects = ["ffi"]`.
  - `diag.auk`: `FileDiag`, and `FileFails { Many([FileDiag]) }` as the program-level error.
- [ ] `check.rs` (1943), `check/expr.rs` (3657), `check/pat.rs` (425), `check/shapes.rs` (629),
      `patterns.rs` (901) exhaustiveness
- [ ] `effects.rs` (647), `units.rs` (267), `holes.rs` (690)
- [ ] `typed.rs` (653)
- [ ] MIR: `mir/mod.rs` (511), `types.rs` (234), `layout.rs` (278), `lower.rs` (3577),
      `lower/pat.rs` (342), `progen.rs` (2167), `print.rs` (581)
- [ ] Diff gates: tokens → AST → diagnostics (codes, messages, spans, fix-its) for every file,
      including `tests/errors/` and `docs/errors/` examples → MIR text.
- [ ] Prelude (`src/prelude/*.auk`) is embedded the same way: one `extern fn ..: str = "#embed .."`
      per file. For now `resolve.auk` reads it from disk (`resolve.sources(dir)`).

**Language freeze** from here to the end of Phase 4: no language changes (or each one is made in
both compilers and both golden outputs). Bug fixes allowed, made in both.

## Phase 4 — Back end and bootstrap

- [ ] `mir/llvm/codegen.rs` (1436), `intrin.rs` (336), `debug.rs` (150, DWARF), `rtlink.rs`
      (226, linking `auk_rt.bc`), `mod.rs` (252), `backend.rs` (52), `exec.rs` (138)
- [ ] Object emission + linking (`build.rs`, 880): still via `cc` for now (Phase 7 removes it).
      FFI pieces are in place (2c gaps): `libauk_rt.a` and `auk_rt.bc` via `#embed`, the link
      line's `-export_dynamic`/`-rdynamic` so built programs (the compiler too) export the
      runtime, `[link]` entries from `llvm-config`, handles in C memory via `"(T)"` casts.
- [ ] ORC JIT (`jit.rs`, 76): runtime symbols resolve from the compiler's own process (it links
      the C runtime, and `auk build` exports its symbols), so no generated symbol table: the
      process search generator (`llvm.kit.jit`) finds them, or `ffi.symbol` + `llvm.kit.define`.
- [ ] Driver: `main.rs` (214) — `run`, `build`, `check`, `test`, `ir`; same flags and exit codes.
- [ ] Diff gate: program output identical for the whole corpus; `auk ir` identical; `bench/perf`
      generated code within ±5% (same MIR → same IR should make this free).
- [ ] **Bootstrap fixed point:** stage 1 (built by Rust) compiles `compiler/` → stage 2; stage 2
      compiles it → stage 3; stage 2 and stage 3 are bit-identical. Requires deterministic output
      (no hash-order iteration, no timestamps/paths in objects).
- [ ] Self-compile time measured and acceptable (target: a full rebuild of the compiler in
      under ~30 s; set the real number from the pilot).
- [ ] Freeze ends. Tag `v0-rust-final`.

## Phase 5 — Tools

Port onto the Auk compiler, each with its existing tests passing:
- [ ] `fmt/` (doc 298, mod 1597, tests 354)
- [ ] `repl.rs` (878), `explain.rs` (169), `dive`
- [ ] `lsp.rs` (1420), `dap.rs` (521), `debug.rs` (887), `dbg_eval.rs` (149)
- [ ] `mcp.rs` (705), `live.rs` (549), `hatch.rs` (484)
- [ ] `raft` (492 + manifest 276, toml 358, semver 127, sha256 65) — HTTP via the runtime's net/tls
- [ ] Threads: tools that use `std::thread` (`dap`, `debug`, `mcp`, `live`, `hatch`) use Auk
      tasks/channels instead.
- [ ] Integration tests: `tests/*.rs` (24 files) become an Auk test runner over the same
      fixtures (spawns the binaries, compares output).
- [ ] VS Code extension (`editors/vscode`) still works against the new `lsp`/`dap`.

## Phase 6 — Retire Rust

- [ ] **Bootstrap seed:** release binaries per platform (macOS arm64/x86_64, Linux x86_64/arm64),
      plus checked-in LLVM bitcode (or textual IR) of the compiler, so a fresh checkout builds
      with LLVM alone — no previous `auk` needed.
- [ ] Build script (`make`/`build.sh`): seed → stage 1 → stage 2, runtime, tools, tests.
- [ ] Delete `Cargo.toml`, `Cargo.lock`, `build.rs`, `runtime/build.rs`, `src/`, `.cargo/`, `target/`.
- [ ] Install moves off `~/.cargo/bin` (e.g. `~/.auk/bin` or `/usr/local`); update README, docs,
      `site/index.html`, editor settings.
- [ ] Release process: how a new seed is cut (every release, from the fixed point).

**Done when:** no `.rs` in the repo; fresh clone + LLVM + C compiler builds and passes everything.

## Phase 7 — Runtime to Auk (Auk only)

### 7a. Low-level Auk (gated: only `runtime/`, like `extern fn` in the prelude)
- [ ] Raw pointers: `ptr[T]`, load/store, offset, cast, null; `sizeof`/`alignof`.
- [ ] `#[repr(C)]` structs and unions, fixed-width ints (`u8 … i64`, `usize`), bit ops.
- [ ] **No-RC mode:** functions/types the compiler never refcounts or copies — needed because
      the allocator and RC machinery are written in it and can't call into themselves.
- [ ] Atomics (load/store/CAS/fetch-add with orderings), thread-locals, fences.
- [ ] `export fn` with the C ABI and a fixed symbol name; calling conventions for callbacks
      (CoreAudio render callback, pthread start routine, qsort-style comparators).
- [ ] Inline hints / `always_inline` so small runtime functions still inline into programs.
- [ ] Compile-time layout checks (equivalent of `_Static_assert`).

### 7b. Things that were C-only
- [ ] `catch` without setjmp in C: either an LLVM setjmp/longjmp intrinsic, or (better) move
      `catch` to LLVM landing pads / unwinding — decide early, it affects codegen.
- [ ] ObjC: call `objc_msgSend`/`sel_registerName`/`objc_getClass` via FFI to replace
      `gui_host.m` and `audio_out.m`; blocks (if any AppKit API needs them) via a small
      block-literal layout in Auk.
- [ ] Network.framework/OpenSSL bindings via FFI (Network.framework uses blocks — check;
      fall back to Security.framework `SecureTransport` alternatives or OpenSSL on macOS too).
- [ ] Ryu, Unicode tables, `buf_printf` → Auk.
- [ ] Varargs: none in our API by then (Phase 1 rule); calling libc varargs (`printf`, `open`
      with mode) via fixed-arg wrappers or varargs FFI support.

### 7c. Port
- [ ] Same order as Phase 1c, one module at a time, C and Auk linked together meanwhile.
- [ ] `auk_rt.bc` is produced by the Auk compiler; `libauk_rt.a` via LLVM's archive writer.
- [ ] Same C tests (called through `export fn`), then rewrite them as Auk tests.
- [ ] ASan/UBSan equivalent: build the runtime with LLVM sanitizer passes from the Auk compiler.
- [ ] ±5% perf bar against Phase 1 numbers.

### 7d. Drop the C compiler from the toolchain
- [ ] Linking: `auk build` currently runs `cc` (`AUK_LINKER`). Switch to calling the system
      linker directly (`ld` on macOS with the right `-syslibroot`/`-platform_version`;
      `ld`/crt objects on Linux) or embed LLD via the LLVM binding.
- [ ] `dsymutil` for `-g` on macOS: keep calling it (ships with Xcode CLT / LLVM) or use
      LLVM's library.
- [ ] Delete `runtime/c/`; build script needs only `auk` + LLVM.

**Done when:** no `.c`, `.h`, `.m`, `.rs` in the repo; a fresh machine with LLVM and the seed
builds and passes everything.

---

## Cross-cutting

- **Determinism** (needed for the fixed point): ordered maps or sorted iteration wherever output
  depends on it; no addresses/timestamps in output.
- **Error-message parity:** every diagnostic and runtime error string stays byte-identical
  through every phase — the golden corpus and `docs/errors/` enforce it.
- **Platform matrix:** macOS arm64 is primary; Linux x86_64 must pass at the end of each phase.
- **Docs:** `docs/compiler.md`, `README.md`, site, error docs updated at the end of each phase.
- **Memory/debugger/fault-tolerance plans:** `--debug`, DAP, `catch`/supervisors, per-task heaps
  must keep working at every step (their tests are in the suite).

## Risks

- **Compiler speed in Auk** — refcounting and copies on a ~37k-line program. The Phase 2 pilot
  measures it before the big commitment.
- **Length of the freeze** — Phases 3–4 are the bulk of the work. Keep them moving; don't run
  big language work in parallel.
- **FFI ergonomics** — the LLVM C API is pointer-heavy. Fallback: emit textual LLVM IR and call
  `llc`/`clang`, losing in-process JIT until bindings are ready.
- **Unsafe dialect creep** (Phase 7) — low-level Auk stays gated to `runtime/` so ordinary Auk
  stays safe and the LLM-facing language stays small.
- **`catch` mechanism** (Phase 7) — replacing setjmp touches codegen, the debugger and per-task
  heaps; prototype it before porting `rc`/`heap`.
- **Bootstrap rot** — if the seed can't be rebuilt, the project is stuck; keep `v0-rust-final`
  buildable and cut seeds from the fixed point every release.

## Rough sizing

| Phase | Work | Relative size |
|---|---|---|
| 0 | baselines, golden corpus, CI | S |
| 1 | runtime → C (~11k lines) | L |
| 2 | FFI, LLVM binding, pilot, language gaps | M–L |
| 3 | front end → Auk (~22k lines) | XL |
| 4 | back end, driver, fixed point (~4k lines + build) | L |
| 5 | tools → Auk (~11k lines) | L |
| 6 | seed, build script, delete Rust | S |
| 7 | low-level Auk, runtime → Auk, own linking | L–XL |
