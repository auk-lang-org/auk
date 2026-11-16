# Duck compiler architecture

The language is `docs/spec.md`; packages and the core library are in `docs/quack.md`. This file says how the compiler is built. Every phase is checked against the **corpus**: `examples/*.duck` plus `packages/*/src/*.duck`. "Done" means the corpus compiles and its `test` blocks pass.

## Pipeline
```
source ─▶ lex ─▶ parse ─▶ resolve ─▶ check ─▶ lower ─▶ C codegen ─▶ cc + libduckrt ─▶ native exe
         tokens   AST     modules,   types,    explicit        .c        clang -O2
                          names      patterns, RC/control
                                     effects,  flow
                                     shapes
```
- **No external crates.** Cargo.toml has zero dependencies and keeps it that way.
- **Backend = C.** The compiler emits one C file per program, `#include "duck.h"`, and links against the C runtime in `runtime/`.
- clang compiles both the generated C and the runtime, with `-O2 -std=c11 -pthread -lm`. `CLANG` overrides the compiler.

## Source layout
| file | contents |
|---|---|
| `src/main.rs` | the `duck` CLI: command dispatch, `check`, and the hidden `parse`/`typed` debug commands the tests use |
| `src/token.rs`, `lexer.rs` | tokens with spans; the newline rule, interpolation parts, raw/triple strings and escapes are all lexer jobs |
| `src/ast.rs` | the full AST: items (fn clause, struct, enum, shape, test, top-level let/imprint), patterns, expressions, types; every node has a `Span` |
| `src/parser.rs` | recursive descent; precedence climbing per the spec's table; groups clauses after parsing |
| `src/resolve.rs` | the module tree (project `src/**` + `.quack/<dep>/src/**` + core), path resolution |
| `src/prelude/*.duck` | the core library as Duck source compiled into the compiler: `extern fn` bindings to the runtime, `@` intrinsics, and generic collection functions written in Duck |
| `src/types.rs`, `check.rs`, `check/*.rs` | types, inference driven by the expected type, local scopes, overloading and UFCS, patterns (typing), shapes (fit, monomorphization, vtables), auto-wrapping to `T?`/`T!`; diagnostics E0100–E0399 |
| `src/units.rs` | units of measure: parsing `<m/s^2>` into a canonical form (sorted base units, integer exponents), display, and `erase` (`check::check` strips every unit from the typed program, so codegen only sees `int`/`float`; the language server keeps them for hovers; interpolation parts with a unit are in `Tables::units`) |
| `src/typed.rs` | the typed program handed to codegen: side tables keyed by NodeId, resolved call targets, instances to emit (its module docs are the codegen contract) |
| `src/patterns.rs` | exhaustiveness and reachability (the usefulness algorithm) |
| `src/effects.rs` | `uses` checking, the quack.toml effects ceiling, imprint purity |
| `src/lower.rs`, `lower/pat.rs` | function bodies → C statements, straight from the typed AST (RC retain/release, explicit control flow, pattern tests) |
| `src/cgen.rs` | C representations of types, derived functions, literals, constants, the `main` shim |
| `src/build.rs` | whole-program generation, the embedded runtime, clang, imprints, and `run`/`build`/`ir`/`test` |
| `src/diag.rs` | diagnostics with **stable codes** (`E0001`…), spans, notes and fix-it edits; renders human text or JSON |
| `src/holes.rs`, `src/hatch.rs` | `duck holes` (a brief per `??` hole: expected type, locals in scope, contracts, the tests that call it; JSON schema in its module docs) and `duck hatch` (fills holes with the model command `DUCK_HATCH_CMD`, checking and testing each answer and feeding errors back) |
| `src/explain.rs` | `duck explain`: the pages in `docs/errors/*.md`, compiled in |
| `src/fmt/` | `duck fmt`: a Wadler-style document printer over the AST |
| `src/repl.rs`, `src/lsp.rs`, `src/json.rs` | `duck pond` (the REPL), `duck lsp` (the language server) and its JSON |
| `src/bin/quack.rs`, `src/bin/quack/` | the `quack` package manager (manifest, semver, TOML, SHA-256) |
| `runtime/duck.h`, `runtime/*.c` | the C runtime (below), with its own C unit tests in `runtime/test/` |

## Runtime ABI (runtime/duck.h is the source of truth)
- **Scalars:** `int` → `int64_t` (all arithmetic is checked; overflow calls `duck_panic`), `float` → `double`, `bool` → `bool`, `char` → `uint32_t` (code point).
- **Heap objects** begin with `DuckHeader { _Atomic int64_t rc; uint32_t kind; }`. `duck_retain(p)` / `duck_release(p)` (frees at 0, releasing children). They're atomic because async tasks run on threads.
- **str:** an immutable UTF-8 buffer with a byte length, a cached char count and an `is_ascii` flag. Char indexing is O(1) when ASCII. Interning isn't needed.
- **[T]:** a header plus `len`, `cap` and `elem_size`, with elements stored inline (generic code is monomorphized, so element types are known statically). Copy-on-write: mutating with `rc > 1` copies first. A slice `xs[a..b]` / `[h, ..t]` is a view {base, offset, len} that shares the buffer (O(1)).
- **{K: V}:** an insertion-ordered hash map (an index table plus an entries array), copy-on-write.
- **Tuples and structs:** plain C structs, passed by value; RC fields are retained and released by generated code. **Enums:** a tagged union. A recursive variant field is boxed automatically (a heap cell with a header).
- **T?** → `{bool some; T val}`. **T!** / **T!E** → `{bool ok; T val; DuckErr err}`, where `DuckErr` is a heap object (message, code, cause, plus an optional typed payload with a type id, so `err(BadUrl(w))` can match after conversion).
- **Closures:** `{fnptr, env*}`, with the env heap-allocated and reference-counted.
- **Value:** a C enum mirroring core `Value`. The compiler generates `to_value`/`from_value` per type.
- **Async:** `async fn` compiles to a normal C function plus a thunk. Calling it without `await` creates a `DuckTask` (a thunk run on a pthread pool). `await t` joins. `await (a, b)` / `await [..]` starts everything and then joins all of them. A direct `await f(x)` just calls `f` (no thread).
- **Core library in C:** fs, net (tcp; tls via the system's TLS library if available, otherwise a clean `Err("tls unavailable")`), time, rand, env, proc, string and collection primitives, float formatting (shortest exact output), and `print`.
- **Panics** (overflow, index out of range, a failed `requires`, an unfilled hole, unwrapping `none`) print `panic: <msg>\n  at file:line:col` and exit 101.

## Contracts, holes, tests, peek, imprint (codegen)
- `requires` → a check at function entry, in every build. `ensures` → a check at every return in debug and test builds; `old(e)` values are captured at entry.
- `??` → `duck_hole("file:line", "expected T")`. `duck build` (release) refuses a program that still has holes; `run`, `check` and `test` allow them.
- `duck test [path]` builds a test binary with every `test` block (including the dependencies' tests only when `--deps` is given), runs each in a forked child process (so a panic fails one test and the rest keep running), and prints `ok`/`FAIL` lines plus a summary. Exit code 1 on any failure. A directory means its project's `src/lib.duck` or `src/main.duck`; a directory with neither (like `examples/`) is treated as flat: each top-level `.duck` file with `test` blocks is built as its own program (with the directory's `quack.toml` dependencies), run in sorted order under a `== <file>` header, followed by a combined `== N files: P passed, F failed` line.
- `peek e` → prints `[file:line] <source text of e> = <show(value)>` to stderr and returns the value.
- `imprint X = e` → the compiler builds a tiny helper program that evaluates `e` (pure functions only) and prints `to_value(e)`. It then embeds the result as a constant. No interpreter is needed.

## Back end as built (lower.rs, cgen.rs, build.rs)
- `cgen.rs`: C representations, refcount helpers, element ops, derived `Show`/`Eq`/`Ord`/hash/`to_value`/`from_value`, literals, constants, the `main` shim. `lower.rs` (+ `lower/pat.rs`): bodies, straight from the AST + side tables (no separate IR); every value is an owned temporary or a borrowed operand, scopes release on every exit. `build.rs`: whole-program generation, the embedded runtime, clang, and `run`/`build`/`ir`/`test`.
- Patterns compile to sequential first-match tests (no decision trees). Self tail calls in tail position become `goto` loops; other recursion stays recursive.
- A struct or enum field whose type contains the type itself by value is boxed.
- Top-level `let`s are lazily initialized globals (initialized at startup, released by the leak-check cleanup).
- `imprint`s are computed at compile time (`build.rs`, `eval_imprints`): the compiler generates a helper program from the same typed program in which each imprint is computed through its constant getter (so imprints may use other imprints and `let`s in any order) and its derived `to_value` tree is written to a records file; the compiler parses it and emits each imprint as a global built from that data at startup out of immortal objects (literal strings, lists, maps, boxes), with no initializer code. A panic while computing one is E0420 at the imprint (with the panic message and location); a cycle through function calls is E0115; a type that isn't `Data` is E0350 (in the checker). Nothing is cached.
- A write through a boxed field (`a.boss.pay += 1`, `a.b.c.v = 1`) first makes each box on the path unique (copy-on-write, like lists and maps).
- `ensures` (debug builds): the function becomes a wrapper around the clause group's body. The wrapper finds the clause that matches (pattern tests and pure guards, in order), binds its names, captures the header's and that clause's `old(e)` values, calls the body and checks those `ensures`. Self tail calls stay loops inside the body; the wrapper checks the outer call's result.
- **Execution traces** (`duck run --trace=json|<file>`, `duck test --trace=json|<dir>`, `--trace-limit N`, `--trace-core`; runtime/trace.c). A codegen flag (`cgen::Trace`): without it the generated C is unchanged. With it, every Duck function outside core (with `--trace-core`, core's too) is emitted as `<name>_untraced` plus a wrapper `<name>` that records a `call` event with the arguments shown (debug `Show`), calls it, and records `ret` with the shown value, or `err` for a `T!` that failed; every direct call to a traced function first sets `duck_trace_site` (its call site), and `main` calls `duck_trace_init`. Self tail calls stay loops inside `_untraced`, so a tail-recursive loop is one call/ret pair. The runtime adds `peek` events (`duck_peek`), `panic` (`duck_panic`) and `signal` (a crash handler on an alternate stack, so a stack overflow still writes its trace), and the test runner a `test` event per test. Events, one JSON object per line:
  `{"ev":"call","fn":"calc.eval","loc":"calc.duck:66:30","args":["Lit(2.0)"],"depth":3}` (`loc`: the call site, or the definition when called through a function value), `{"ev":"ret","fn":"calc.eval","value":"2.0","depth":3}`, `{"ev":"err","fn":"calc.eval","error":"DivZero","depth":3}`, `{"ev":"peek","loc":"f.duck:5","expr":"x * 2","value":"84","depth":1}`, `{"ev":"panic","msg":"...","loc":"f.duck:3:36","depth":4}`, `{"ev":"signal","signal":11}`, `{"ev":"test","name":"t","result":"ok"|"FAIL"}`, `{"ev":"truncated","limit":10000}` (the stream stops after the limit; a final panic/signal is still written) or, at the start of a tail, `{"ev":"truncated","skipped":N}`. Values are cut to 200 chars, and showing one is bounded work (a byte budget in the runtime's string builder stops list/map/str shows early), so a huge argument costs O(1) per call. Nothing is traced while a value is being shown (a user `show`). Configuration reaches the program through the environment (`DUCK_TRACE` = file, directory or `-`; `DUCK_TRACE_LIMIT`; `DUCK_TRACE_TAIL`, default 20): `duck test --trace=json` keeps each test's last events in a ring and the runner prints them under its FAIL line; `duck hatch` does the same (12 events) so a retry prompt shows what the candidate actually did.
- `DUCK_LEAK_CHECK=1` makes `duck run` / `duck test` binaries fail when runtime objects are still live at exit; `DUCK_CFLAGS` adds C flags (sanitizers); `DUCK_KEEP_C=<path>` keeps the generated C.

## CLI
`duck run|build|check|test|fmt|explain|pond|lsp|ir|spec`, plus `quack`. `duck ir [--trace] <file>` prints the generated C. `check --json` emits `{file, ok, diagnostics:[{code, severity, line, col, end_line, end_col, message, notes, fixes:[{line, col, end_line, end_col, text}]}]}`.

## Testing
`cargo test` runs the compiler's unit tests plus these integration tests:
- `tests/parse.rs`, `check.rs`, `check2.rs`: the whole corpus parses and checks clean (and its typed program satisfies codegen's invariants); small programs get the exact diagnostic codes, messages and fix-its.
- `tests/run.rs`: every example with a `.out` file runs and matches it (the others run with fixtures from `tests/fixtures/`), every example and package passes `duck test`, leak and sanitizer runs, codegen edge cases, `duck spec`, and every `tests/errors/*.duck` fails `duck check` with the `// error: E0xxx <message>` in its first line.
- `tests/trace.rs`: execution traces (call/ret nesting, errors through `?`, panics, peeks, the limit, a failing test's trace, valid JSON, identical C without the flag, leak-free and warning-free traced builds).
- `tests/units.rs`: units of measure (inference, every unit error, the `3<x` lexing rule, fmt, interpolation, and erasure: the generated C is the same as without units).
- `tests/fmt.rs`, `lsp.rs`, `explain.rs`, `pond.rs`: the formatter (the corpus is fmt-clean), the language server, `duck explain` and the REPL.
- `tests/quack.rs`: the package manager against the registry in `tests/fixtures/registry/`.
- `tests/runtime.rs`: the C unit tests in `runtime/test/*.c`.
