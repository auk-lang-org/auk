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
| Runtime tests | `runtime/c/test/*.c` (was `runtime/tests/*.rs`) | ~3.2k lines C (Phase 1 done) |
| Compiler | `src/` (lexer → check → MIR → LLVM); its Auk port `compiler/src/` | ~42k lines Rust; ~39k lines Auk (self-hosting since Phase 4) |
| Tools | `fmt repl lsp dap debug mcp live hatch explain dive`, `raft` | inside the 42k |
| Integration tests | `tests/*.rs` (24 files) + fixtures; their Auk port `tests/runner/` (360/360 tests) | drive the binaries (any `auk` via `$AUK_BIN`) |
| Build | `Cargo.toml`, `build.rs`, `.cargo/config.toml` (`runtime/build.rs` went with Phase 1) | |
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
- [x] Versioning for the transition: the Rust `auk` is "stage 0" and is tagged
      (`v0-rust-final`) on the last commit before Phase 6 deletes it, so it can always rebuild
      the seed. (First planned for the end of Phase 4; moved because the Rust `auk` stays the
      reference for the Phase 5 ports and gets their bug fixes until then.)

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
- [x] Each call that takes a list (`build_call2`, `build_gep2`, `function_type`) mallocs and frees
      a C array. Measured in Phase 4: the ported code generator is within 2x of Rust's with it.
- [ ] Which `LLVM*Ref` parameters accept NULL and which results may be NULL is a hand list in
      `gen.py` (`NULLABLE_ARG`, `NULLABLE_RET`); porting the rest of the back end will add to it,
      and to `bind.txt` for new functions and enum values. The back end needed no new function;
      `LLVMGetOperand` may return NULL (the port binds it again as `Value?` in `rtlink.auk`).
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
- [x] Process/fs/args/env APIs the driver needs (`auk build` writes temp files, runs the linker,
      `dsymutil`): core's `fs`/`proc`/`env` plus `compiler/src/posix.auk` (fork with redirected
      streams, `waitpid`, `exit`) over `ffi` (Phase 4).

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

- [x] Shared: `diag.rs` (385) diagnostics + fix-its, `json.rs` (434), `types.rs` (554).
      `types.rs` done (3a): `compiler/src/types.auk`. `diag.rs`: `Span`/`Diag`/`Fix`, `FileDiag`,
      the warning list and the `check --json` report (`json_report_files`, 3b); the text
      rendering (`render`, with the fmt port) is diffed through `auk check`'s human output (3c);
      the code table (`CODES`, `title`) and all of `json.rs` (`compiler/src/json.auk`) came with
      the Phase 5 tools port.
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
    files takes a `Sources` (prelude texts, `with_sources` overrides, the OS): the prelude texts
    are compiled in (`embedded.prelude()`, one `#embed` per file). Rust's `BTreeMap` iteration
    is `sorted_keys(m)`.
  - `visit.auk`: `visit_item_exprs`/`visit_expr` (check.rs) push every expression, pre-order,
    onto a `var [ast.Expr]`; `as_path` (check/expr.rs).
  - `paths.auk`: `std::path` on `str` (`join`, `parent`, `file_stem`, `extension`, component
    order, `is_under`/`strip_base`), `canonicalize`/`cwd` (C `realpath`) and `os` (C `uname`), so
    `compiler/` declares `effects = ["ffi"]`.
  - `diag.auk`: `FileDiag`, and `FileFails { Many([FileDiag]) }` as the program-level error.
- [x] `check.rs` (2086), `check/expr.rs` (3835), `check/pat.rs` (482), `check/shapes.rs` (633),
      `typed.rs` (662), `ffi.rs` (551), `units::erase` (3b): `check.auk`, `check_expr.auk` +
      `check_ops.auk` (expr.rs split at `place`), `check_pat.auk`, `check_shapes.auk`,
      `typed.auk`, `cffi.auk`. Oracles: `auk dump check <file>` (the `check --json` report of
      `check::check_types`, i.e. before patterns.rs/effects.rs) and `auk dump typed [--core]
      <file>` (the typed program MIR lowering consumes: signatures, every node's side-table facts,
      locals, instances with resolved targets, concrete types, shape impls, vtables; unit test
      `dump::tests::typed_dump`). `scripts/diff_check.sh` and `scripts/diff_typed.sh`: **924
      files, 0 differ** each, over the corpus plus `tests/checker/` (662 programs extracted from
      the Rust tests and the `docs/errors/` examples, nearly every checker diagnostic, plus
      `ffi_project/` for FFI casts and `#embed`). Checker
      alone 1.28x Rust after three fixes (pilot-report.md, "3b").

  **What the next steps build on**: `check.check_types(prog): (typed.TypedProgram?,
  [diag.FileDiag])` (Rust's `check_types`); `typed.auk` has every side table as `{int: X}`
  keyed by node id, ids are `int`s, `types_used` is a list sorted by `types.cmp` (Rust's
  `BTreeSet<Ty>` order, which instance numbering depends on); `units.erase(&tp)` gives what
  `check::check` returns. `Checker` methods live in four files; each method of another file has a
  forward in `check.auk` so `c.f(..)` works everywhere (gap 1 of 3b): add new cross-file methods
  the same way. `check_shapes.visit_pat`/`visit_expr_pats` push patterns like `visit.auk`.
- [x] `patterns.rs` (901) exhaustiveness, `effects.rs` (647), `holes.rs` (690), `check_all` /
      `check_partial` and main.rs's `check_file` (3c): `patterns.auk`, `effect_check.auk` (a
      module named `effects` would collide with the many locals of that name: E0116),
      `holes.auk`, `cli.auk`, `check.check_all`. The Auk driver now has `compiler check [--json]
      <file>` and `compiler holes [--json] <file>` with `auk check`/`auk holes`'s stdout, stderr
      and exit code, and the oracles are those commands themselves: `scripts/diff_check.sh`
      (`check --json`), `scripts/diff_check_text.sh` (`check`: the rendered diagnostics) and
      `scripts/diff_holes.sh` (`holes`, `holes --json`) compare all three streams: **959 files,
      0 differ** each. `tests/checker/` gained `pat_*` (or-pattern alternatives, lists, literals,
      structs, options/typed errors, guards, `Value`/maps, binding patterns, one-line arms),
      `eff_chains` (hidden effects through generic instances, closures, function values, `Show`
      impls, `any Shape`, combined E0410+E0411 fixes, `uses` anchors after multi-line parameter
      lists), `hole_scopes`, `effects_project/` and `effects_none/` (E0413 against raft.toml),
      and the remaining programs the Rust tests run through `auk check`/`auk holes`.
      All of `auk check` 1.40x Rust in-process, the two new passes 2.47x (pilot-report.md, "3c").

  **What the next steps build on**: `check.check_all(prog)` / `check.check_partial(prog)` (Rust's
  names and results); `patterns.children(e)` (the direct sub-expressions in source order, Rust's
  `patterns::children`); `cli.print_diags(cx, diags)` renders diagnostics to stderr against each
  file's text (`resolve.source_of`); `holes.discover(tp)`/`holes.brief_text`/`holes.hole_json`
  for `auk hatch` and the MCP tools.
- [x] MIR: `mir/mod.rs` (511), `types.rs` (234), `layout.rs` (278), `lower.rs` (3577),
      `lower/pat.rs` (342), `progen.rs` (2167), `print.rs` (581) (3c). The data model, layouts
      and printer came with the back-end port (`mir.auk`, `mir/types.auk`, `mir/layout.auk`,
      `mir/printer.auk`); the lowering is `mir/progen.auk`, `mir/lower.auk`,
      `mir/lower/pat.auk`, `mir/lower/ffi.auk` and `mir/build.auk` (build.rs's `generate`, the
      debugger tables, the imprint helper and its records). `compiler ir [--release] [-g]
      [--trace=..] [--debug] <file>` prints what `auk ir` prints. Imprints run a helper program:
      the port JIT-compiles it and runs it in a forked child itself since Phase 4
      (`drive.eval_imprints`; until then the Rust run left its records for the port in
      `AUK_IMPRINT_RECORDS`, now removed); `AUK_IMPRINT_EVAL_IR=<f> auk ir` writes the helper's
      MIR, diffed against `compiler ir --imprint-eval`. `scripts/diff_ir.sh`: **213 programs x 5
      variants (run, --release, --release -g, --trace=json, --debug) and 27 imprint helpers, 0
      differ** (the back end's corpus plus `compiler/tests/ir/`; E0115/E0420 imprint failures
      included). The compiler
      itself (`compiler/src/main.auk`, 7.9 MB of MIR) lowers identically. `lower::emit_eval`
      (the debugger's expression evaluation) came with `debug` in Phase 5. Lowering
      alone is 1.54x Rust as ported (`scripts/ir_time.sh`; pilot-report.md, "3c").

  **What Phase 4 builds on**: `mir.build.generate(tp, mode, trace, imprints, embeds):
  Generated!` (`prog`, `info`, `dbg`, `holes`, `tests`, `live_keys`) is the program the back
  end compiles, with `mir.build.embeds(tp)` (the `#embed` files, read up front so lowering needs
  no `fs`) and `mir.build.imprint_program(tp, embeds)` (the helper to JIT-run; then
  `imprint_results(tp, records, code, stderr)`). `Program::live_keys` is `Generated.live_keys`
  (the reader's `mir.Program` has no field for it).
- [x] Diff gates: tokens → AST → diagnostics (codes, messages, spans, fix-its) for every file,
      including `tests/errors/` and `docs/errors/` examples → MIR text: `diff_tokens`, `diff_ast`,
      `diff_resolve`, `diff_check` (all of `auk check --json`, patterns and effects included),
      `diff_check_text`, `diff_holes`, `diff_typed`, `diff_ir`, all in `scripts/check.sh`'s pilot
      step, 0 differ.
- [x] Prelude (`src/prelude/*.auk`) is embedded the same way: one `extern fn ..: str = "#embed .."`
      per file (`compiler/src/embedded.auk`, with `docs/spec.md` and the `docs/errors` pages;
      Phase 4). `resolve.sources(dir)` still reads a prelude directory, for tools.

**Language freeze** from here until the Rust compiler is deleted (Phase 6): no language changes
(or each one is made in both compilers and both golden outputs). Bug fixes allowed, made in both.

## Phase 4 — Back end and bootstrap

Started decoupled from Phase 3: the Rust compiler writes the MIR (`auk dump mir`), the Auk back
end reads it and must produce the same LLVM IR, executables and program output. Status and
numbers: [pilot-report.md](pilot-report.md), "Phase 4".

- [x] MIR in Auk: `mir/mod.rs` (data model), `types.rs` (the layout facts of `TyInfo`),
      `layout.rs`, `print.rs` → `compiler/src/mir.auk`, `mir/types.auk`, `mir/layout.auk`,
      `mir/printer.auk`. `auk ir` is C-like and lossy (`int` and `int64_t` print alike), so the
      Rust compiler got a machine-readable form: `auk dump mir [--release] [-g] [--test]
      [--trace..] [--debug] <file>` (`src/mir/dump.rs`, unit test `mir::dump::tests::mir_dump`:
      prefix tokens, every machine type and member, float bits, byte strings, plus the type
      definitions the layouts need), read by `mir/reader.auk`. Round trip
      (`scripts/diff_mir.sh`): the port reads each dump and prints the MIR text; **1045 dumps (209
      programs × run, release, release -g, traced, debugger), 0 differ**.
- [x] `mir/llvm/codegen.rs` (1436), `intrin.rs` (336), `debug.rs` (150, DWARF), `rtlink.rs`
      (226, linking `auk_rt.bc`), `mod.rs` (252), `backend.rs` (52) → `compiler/src/codegen.auk`,
      `intrin.auk`, `dwarf.auk`, `rtlink.auk`, `backend.auk`, line by line over `packages/llvm`.
      `exec.rs` (138): running the entry in this process (`orcjit.run`), and forked children
      (`drive.auk`, Phase 4 driver); `jit_eval` (debugger evaluation) is `backend.jit_eval`
      (Phase 5, with `debug`); `jit_live` (live reload) is `backend.jit_live` (Phase 5, `live.rs`).
      Oracle: `auk ir --llvm=LEVEL` (`o0` is `auk ir --llvm`; `light`, `o2`, `o3`, `build` = O2
      with the runtime's bitcode; `-raw`: before the pass pipeline). `scripts/diff_llvm.sh`
      compares 13 IR texts per program (o0, o0-raw, light-raw, light, o2, o3; release build and
      build-raw; build -g with DWARF; traced and debugger builds at o0 and light): **26 programs,
      338 IR texts, 0 differ**.
- [x] Object emission + linking (`build.rs` `build_native`) → `compiler/src/native.auk`: object
      file, `cc` with the embedded `libauk_rt.a`, `[link]` libraries (`${VAR}`/`$(tool)`
      expanded), the platform's libraries, `-export_dynamic`/`-rdynamic`, `dsymutil` for `-g`.
      `libauk_rt.a` and `auk_rt.bc` are `#embed`ded from `target/auk-rt/`, where build.rs now
      copies them (the cargo build must run first; a sanitized runtime isn't copied).
- [x] ORC JIT (`jit.rs`, 76) → `compiler/src/orcjit.auk`: the object linked by LLJIT; each runtime
      symbol the module calls (the code generator's declarations) defined at its address in the
      compiler's own process (`ffi.symbol`, `llvm.kit.define`), everything else (libc, user C
      libraries `dlopen`ed `RTLD_GLOBAL` as `open_libs` does) through the process search
      generator; the entry called by address (`"int (*)(int, void *)"`).
      `scripts/run_backend.sh`: every `run` and project `test` entry of `golden_runs.txt` plus
      `compiler/tests/backend/` (closures, tasks, channels, `catch`, shapes, contracts,
      imprints, recursive enums, `Value`, inlined runtime calls, FFI by prototype, by address,
      casts, `#embed`) compiled from the dump by the port and run in its own process (`auk run`'s
      level; tests at O0), and every `run` program also built by both into executables: **48
      programs, 0 differ** (stdout, stderr, exit code). The port compiling the Auk compiler's own
      MIR (`pilot_tokens`/`pilot_ast`) is among them. On Linux (AArch64, the CI image) too:
      diff_mir 130 dumps, diff_llvm 78 IR texts, run_backend 48 programs, 0 differ.
- [x] Driver: `main.rs` (214) → `compiler/src/main.auk` (the `auk` command), `drive.auk`
      (build.rs's driver half: check, generate, JIT run, `build_native`, trace flags, project
      roots, flat test directories), `posix.auk`, `embedded.auk` (prelude, spec and error pages
      `#embed`ded: the binary needs no checkout). `run`, `build`, `test`, `check`, `ir`, `fmt`,
      `holes`, `hatch`, `explain`, `spec`, `lsp`, `mcp`, `__jit` (with `AUK_SOURCES`, so `hatch`
      builds its candidates with itself), same flags, output and exit codes. Imprints run in a
      forked JIT child (`drive.eval_imprints`). `debug`, `dap`, `dive` and `run --live` came in
      Phase 5. `scripts/diff_driver.sh`: 53 cases (usage errors, traces, `-O`, `build -o -g`,
      imprint panics, test filters, flat directories, the leak checker), 0 differ.
- [x] Diff gate: `scripts/golden.sh --compare` with stage 2: tokens, ast, check, fmt 997 files,
      ir 213, run 46 entries, 0 differ. `tests/*.rs` against stage 2 (`AUK_BIN`): 505 pass, 0
      fail (the count includes tests that return early because they need `debug`, `live`,
      `parse` or `typed`, which the port lacks: `PORT_LACKS` in `tests/auk_bin/mod.rs`).
      `bench/perf`: all 7 executables byte-identical to the Rust `auk`'s.
- [x] **Bootstrap fixed point** (`scripts/bootstrap.sh [--perf]`; `check.sh bootstrap`): stage 1
      (built by Rust), stage 2 and stage 3 are all bit-identical (5.17 MB).
- [x] Self-compile time: 26–33 s per stage (Apple M5; `auk build compiler/src/main.auk`, an O2
      release build) — the same as the Rust `auk` building it (~27 s), at the ~30 s target.
- Freeze and the `v0-rust-final` tag: moved to Phase 6 (the Rust `auk` is still the oracle for
  the Phase 5 ports).

## Phase 5 — Tools

Port onto the Auk compiler, each with its existing tests passing:
- [x] `fmt/` (doc 298, mod 1597, tests 354): `compiler/src/fmt.auk`, `fmt/doc.auk`,
      `fmt/tests.auk` (the 25 unit tests as `test` blocks); `compiler fmt [--check] <path>... | -`.
      `scripts/diff_fmt.sh`: Rust `auk fmt -` and the port agree on all 258 corpus files
      (stdout, stderr, exit code; 108 parse-error files included), and both are idempotent.
      Timing and gaps: pilot-report.md, "Phase 5".
- [x] `explain.rs` (169) + `diag.rs` `CODES`, `json.rs` (434), `lsp.rs` (1420), `mcp.rs` (705):
      `compiler/src/explain.auk` (162; the pages embedded with one `#embed` extern each in
      `error_pages.auk`, generated by `scripts/gen_error_pages.sh`, which check.sh runs with
      `--check`), `json.auk` (361), `lsp.auk` (1537), `mcp.auk` (789, with `compiler spec`:
      docs/spec.md embedded), `stdio.auk` (56: C stdio for the servers' framing).
      `compiler explain [E0xxx]`, `compiler lsp`, `compiler mcp`, `compiler spec`.
      **Oracles:** `scripts/diff_tools.sh`: `explain` of every code (and unknown ones) = Rust's;
      `scripts/diff_lsp.py` drives both servers through whole sessions (symbols, formatting,
      code actions, hover and definition every 4th column of every line): **981 corpus files,
      0 differ** (918k messages; `compiler/src` every 8th column); `scripts/diff_mcp.py`: one session of
      protocol errors and tool calls, 29 replies, 0 differ. `tests/lsp.rs`, `tests/mcp.rs`,
      `tests/explain.rs` run against any binary named by `$AUK_BIN` (`tests/auk_bin/mod.rs`):
      with the port all pass. Since the Phase 4 driver the MCP `auk_run`/`auk_test` tests and
      explain's E0420 example run too; still skipped (with a note): MCP `auk_debug` (`debug`)
      and explain's wrong examples of lexing/parsing codes (`parse`). Gaps: pilot-report.md,
      "Phase 5".
- [x] `repl.rs` (878), `dive`: `compiler/src/dive.auk` (983 lines, the 3 Rust unit tests as
      `test` blocks), `auk dive [--quiet]` in the Phase 4 driver; each input's program is
      generated and JIT-compiled in process (`drive.generate`, `backend.jit` at O0) and runs in a
      forked child with stdin from `/dev/null` and stdout and stderr merged in one file (new:
      `posix.run_forked_merged`, Rust's `Redirect { merged, stdin_null }`).
      `scripts/diff_dive.sh` (in check.sh's pilot step): 23 scripted stdin sessions plus one on
      a terminal (`script`: banner, prompts, `..`, Ctrl-D) — every `:` command and its aliases,
      values of every kind, definitions then uses, redefinitions, clause groups waiting for more
      clauses (`..`, blank line, EOF), type errors mapped to input lines, panics, `fail`,
      contracts, multi-line inputs (operators, brackets, `"""`, block comments), syntax
      errors, `:load`/`:save` (the saved files compared too), CRLF, `--quiet`/`-q`, bad flags:
      **0 differ** (stdout, stderr, exit code). `tests/dive.rs` now runs `$AUK_BIN`: 4 pass
      against the port. Gaps: pilot-report.md, "Phase 5", dive.
- [x] `dap.rs` (521), `debug.rs` (887), `dbg_eval.rs` (149): `compiler/src/dap.auk` (567),
      `debug.auk` (1215 as `auk fmt` lays it out; ~250 lines of it the FFI Rust's `std` gives:
      Unix sockets, `poll`, pipes, `posix_spawnp`), `dbg_eval.auk` (227), with
      `lower::emit_eval` → `mir.lower.emit_eval` and `jit_eval` → `backend.jit_eval`; `auk
      debug` and `auk dap` in the driver. C can't call Auk, so the engine's eval hook gained a
      mailbox form in `runtime/c/dbg.c` (`auk_dbg_eval_mailbox`/`next`/`ok`/`err`/`close`),
      served by a task of `auk run --debug`; and a Ctrl-C flag (`auk_dbg_catch_sigint`).
      **Oracles:** `tests/debug.rs` (now on `$AUK_BIN`; 20/20 with the port) and MCP's
      `auk_debug` test (`tests/mcp.rs` 16/16); `scripts/diff_debug.sh` (in check.sh's pilot
      step): 66 `auk debug` commands over `compiler/tests/debug/` (usage errors, batch text and
      `--json`, breakpoints by file:line and function, conditions and failing conditions,
      `--print`/`--eval` expressions incl. assignments, closures, generic instances and
      panicking ones, panics and `--catch`, tasks, program arguments, `--timeout`, compile
      errors, 10 scripted `--repl` sessions), stdout, stderr and exit code: **0 differ**; and
      `scripts/diff_dap.py`, 8 DAP sessions (initialize, launch with stopOnEntry/args/cwd,
      line/function/conditional/exception breakpoints, threads, stackTrace, scopes, variables
      expanded 4 deep, evaluate of paths and expressions, setVariable, continue/next/stepIn/
      stepOut, pause, terminate, disconnect, EOF, protocol errors), 212 messages: **0 differ**
      (output events compared per stream, since their place among engine events is up to the
      scheduler). `scripts/diff_mcp.py` gained 4 `auk_debug` calls: 33 replies, 0 differ.
      Gaps: pilot-report.md, "Phase 5", debug/dap.
- [x] `live.rs` (549): `compiler/src/live.auk` (~650 lines), `auk run --live` in the Phase 4
      driver, line by line: the live table, slots by `Generated.live_keys`, layouts, the
      task-use analysis (`Uses`, `Graph`, `Seen`), restart/cancel; `backend.jit_live`
      (`LiveCode`, Rust's `LiveJit`). The watcher is an Auk task. C can't call back into Auk, so
      the runtime got four small entry points (`auk__live_running`, `auk__live_cancel`,
      `auk__live_install`, `auk__live_reloaded` in `runtime/c/task.c`); mtimes are C `stat`'s.
      **Oracles:** `tests/run.rs` `live_reload_swaps_code_and_keeps_state` and
      `live_reload_restarts_only_the_tasks_using_a_changed_type` pass against the port (`live`
      is out of `PORT_LACKS`): 15 of 15 runs, as the Rust `auk` 15 of 15. `scripts/diff_live.sh`
      (in `check.sh pilot`): 6 scenarios of scripted edits (code swap keeping state, type
      error, signature change, layout restart; a `sup` project whose task-only type changes
      and a touched dependency; module deleted/renamed, root renamed; exit, panic, kill while
      watched, arguments; a missing then ill-typed file; usage) synchronized on the output,
      **0 differ**, 5 of 5 runs. Gaps: pilot-report.md, "Phase 5", live.
- [x] `hatch.rs` (484): `compiler/src/hatch.auk`, `compiler hatch <file> [--hole N] [--tries N]
      [--dry-run]`, now `auk hatch` in the Phase 4 driver; the model command via `posix_spawnp`
      (ffi), the candidates' tests built and run by the binary itself (`auk __jit test`, texts in
      `AUK_SOURCES`; `$AUK_BIN` picks another).
      `scripts/diff_hatch.sh`: 37 commands with a scripted model (every flag and usage error,
      retries, contracts, traces, model failures, a project, a write error): 0 differ, prompts
      included. Gaps: pilot-report.md, "Phase 5", hatch.
- [x] `raft` (492 + manifest 297, toml 358, semver 127, sha256 65): the Auk project `raft/`
      (`auk build raft/src/main.auk`; `main`, `manifest`, `toml`, `semver`, `sha256` line by line,
      plus `res` (the error type) and `paths`; 1.6k lines without tests), all five commands with
      the same stdout, stderr, exit codes, `raft.toml` edits, byte-identical `raft.lock` and
      identical `.raft/` trees. The Rust unit tests are `test` blocks (`auk test raft`: 11 pass).
      `tests/raft.rs` takes `RAFT_BIN`: all 10 pass against the port. `scripts/diff_raft.sh` runs a
      scenario of every command and error (fixture registry, the repository's `packages/`, a copy
      of `examples/live-site`) with both, comparing every output and the whole tree after each
      command: 0 differ. No HTTP was needed: the Rust raft's registry is a directory
      (`RAFT_REGISTRY`, default the checkout's `packages/`), and the port reads the same one. A
      separate project rather than a second binary of `compiler/`: it shares no code with the
      compiler beyond `paths.auk` (copied), and it builds without a `.raft/` of its own.
      Results and gaps: pilot-report.md, "Phase 5", raft.
- [x] Threads: tools that use `std::thread` (`dap`, `debug`, `mcp`, `live`, `hatch`) use Auk
      tasks/channels instead. `mcp` done: each tool call is a task. `hatch` needs none: the
      model's stdin is a file and the tests run in a spawned child. `debug`/`dap` done: the
      socket, output, stdin/request and Ctrl-C readers and the `--timeout` timer are tasks
      sending to one `Chan<In>`; `run --debug`'s expression compiler is a task too. `live` done: the child's
      watcher is a task (started with copies of the slots, files, layouts and `Seen`; it
      polls, compiles on its own heap and installs while the program's `main` runs on the
      main thread).
- [x] Integration tests: `tests/*.rs` (24 files) become an Auk test runner over the same
      fixtures (spawns the binaries, compares output). **`tests/runner/`**, an Auk project of its
      own like `raft/` (no dependencies, so no `.raft/`): `suite/<file>.auk` per
      `tests/<file>.rs`, same test names, order, inputs and expected outputs (12k lines, most
      of it the embedded programs; run.rs's string literals were extracted mechanically, so
      they are byte-identical). **360/360** Rust tests have a counterpart
      (`scripts/test_coverage.sh` lists them per file, from the `#[test]` fns; the 4 copies of
      src/json.rs's unit tests excluded). Design:
      - `cmd.auk`: a `Command` built by value (`t.auk().args([..]).setenv(k, v).cwd(d)
        .stdin(s).timeout(ms).output()` → code, signal, stdout, stderr), or `start()` for a
        live child (lsp, mcp, dap, debug, dive, live reload). `sys.auk`: `posix_spawnp`
        through `ffi` with all three streams on pipes (`poll` feeds stdin and drains both
        outputs, so nothing deadlocks), `addchdir_np` for the cwd, its own process group
        (a timeout, default 300 s, kills the group), close-on-exec pipes plus
        `POSIX_SPAWN_CLOEXEC_DEFAULT` on macOS (a child never holds another test's pipe), SIGPIPE
        ignored in the runner and reset in children; unix sockets for `AUK_DEBUG`.
      - `t.auk`: `t.check`/`t.fail`, `t.skip_if_lacks(cmd, what)` and `t.lacks` (the
        `auk_bin::lacks` mechanism: `$AUK_BIN_LACKS`, default for an `$AUK_BIN` binary what
        the port lacks: `parse,typed` since the Phase 5 ports), `t.scratch` (under `target/test-tmp/<pid>`, removed
        after a green run) and `t.temp` (`$TMPDIR`), `t.install` (raft install, stale lock
        regenerated). JSON through `json.auk`, copied from compiler/src (as raft copies
        `paths.auk`; so is `paths.auk`).
      - Every test runs as a task (`-j`, default the CPU count) under `catch`, so a panic fails
        one test; `raft install` in examples, http, url, log once before (`--no-setup`); filters
        by substring of `suite::name` (`--exact`, `--list`, `--ignored`/`--include-ignored`
        for run.rs's 3 gui tests). Files that ran `CARGO_BIN_EXE_auk` (debug, dive, fmt, parse,
        hatch, net, packages_*, llvm_package) take `$AUK_BIN` too, skipping only where the port
        lacks a command.
      - `scripts/test_runner.sh` (check.sh step `runner`): builds both, runs the runner against
        the Rust `auk` and against `target/pilot/compiler`, then the coverage check.
      **Results:** Rust `auk`: 357 pass (+3 ignored gui tests, which pass on macOS), ~50 s wall
      (the Rust suite: ~57 s); the port: 330 pass, 27 skip (debug 15, dive 4, parse 3, typed 2,
      live 2, units' AST check 1), ~52 s; partial skips inside passing tests as in Rust (explain's
      parse examples, fmt's AST comparison, mcp's `auk_debug`). `RAFT_BIN` = the Auk raft:
      raft.rs 10/10. Deviations (no input or expected output changed): scratch names are unique
      per test instead of per-process counters (tests run in parallel); lsp/mcp servers are
      closed at the end of each test instead of on drop; net.rs's echo client is an ffi socket
      (it needs a half-close, which `net.Conn` lacks); ffi.rs's test library is built once,
      race-free; check2/shadow read `check --json` with `json.auk` (a `null` reads as missing).
      Found on the way: `core.fail(msg)` (core qualified) makes an Err whose message is empty
      (Rust auk and port alike), and `auk fmt` changes compiler/src/json.auk (not fmt-clean).
      Gaps: none; still to come when the commands are ported: the 27 skips. `tests/*.rs` stay
      until Phase 6 deletes them (the coverage check keeps the two in step).
- [x] VS Code extension (`editors/vscode`) still works against the new `lsp`/`dap`:
      `scripts/vscode_e2e.sh [<auk>...]` (check.sh step `vscode`, not by default: it opens a VS Code
      window) runs `editors/vscode/test/e2e/index.js` in a real VS Code (1.146, extension host,
      throwaway user-data and extensions directories) with `auk.path` set to each binary: document
      symbols, hover, go to definition, diagnostics (E0200), formatting, then the extension's
      `auk.debug` command to a breakpoint, stackTrace, variables, evaluate (`add(x, 1) * 2`),
      continue and the program's output. Rust `auk` and the port: 9/9 checks each; a binary that
      does nothing fails.

## Phase 6 — Retire Rust

- [ ] **Bootstrap seed:** release binaries per platform (macOS arm64/x86_64, Linux x86_64/arm64),
      plus checked-in LLVM bitcode (or textual IR) of the compiler, so a fresh checkout builds
      with LLVM alone — no previous `auk` needed.
- [ ] Build script (`make`/`build.sh`): seed → stage 1 → stage 2, runtime, tools, tests.
- [ ] Tag `v0-rust-final` on the last commit with the Rust `auk` (all diffs 0, suite green); the
      language freeze ends with the delete.
- [ ] Delete `Cargo.toml`, `Cargo.lock`, `build.rs`, `src/` (with `src/prelude/` moved, e.g. to
      `compiler/prelude/`, since `embedded.auk` and the tools read it), `tests/*.rs`, `.cargo/`,
      `target/`. `libauk_rt.a`/`auk_rt.bc` are built by `build.rs` today (into `target/auk-rt/`,
      which `compiler/` `#embed`s): the build script takes that over first.
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
- **Length of the freeze** — Phases 3–5 are the bulk of the work. Keep them moving; don't run
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
