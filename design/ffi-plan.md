# Plan: user-level FFI (and the `sqlite` package on top of it)

**Status (2026-11-18): phases 1 and 2 done** (core FFI and linking; spec "C functions",
`src/ffi.rs`, `src/mir/lower/ffi.rs`, `runtime/c/ffi.c`, `compiler/prelude/ffi.auk`, tests/ffi.rs).
Beyond this plan, for the LLVM binding (self-host-plan 2b): `extern type` in user code declares
distinct opaque C pointer types, lists cross as C arrays (`var [T]` copies back), `var`
parameters are out-parameters, `T?` of a pointer is NULL-able, `+free(fn)` frees owned
`char *` results, and a `"T (*)(params)"` prototype calls a C function by its address (passed
first, as an `ffi.Ptr`: JIT-compiled code, `dlsym` results), and a `"(T)"` prototype casts between `ffi.Ptr` and an `extern type` (no call), and `"#embed path"` embeds a file read at compile time (`[int]`, `str`, `ffi.Ptr` or its length `int`). Differences from the text below: a `str` argument passes its own bytes (Auk
strings are already NUL-terminated, so no copy; an embedded NUL ends the C string), and the
helpers live in `runtime/c/ffi.c`. `ffi.null` is a constant; `null`, `is_null`, `addr`, `ptr`,
`offset` are pure, the memory helpers `uses ffi`. `ffi.symbol(name): Ptr?` is `dlsym(RTLD_DEFAULT, name)`; `auk build` links executables with `-export_dynamic`/`-rdynamic` (and the `auk` binary on Linux with `-rdynamic`) so the runtime's `auk_*` symbols are found. Phase 3 (the `sqlite` package) and the LSP
part of phase 4 remain.

Unblocks `sqlite` (design/packages-next.md #2) and later `crypto`. Decision (2026-11-17): a general
FFI, option (a) in the packages-next log, rather than a core `sqlite` runtime module.

## 1. What exists today

- `extern fn f(..): T = "sym"` parses only in the core prelude (E0036, `src/parser.rs`). The callee
  gets Auk's representation: `str` is a `AukStr *` (length-prefixed, not NUL-terminated), and
  `int` is an i64.
- `ffi` is already listed as an effect (`src/effects.rs`, raft's `EFFECTS`), but nothing uses it.
- The JIT resolves only `rt_symbols()`. `auk build` links `libauk_rt.a` plus a fixed set of
  system libraries (`src/build.rs`).
- The back end can already call C with `I32`/`U32`/`I64`/`Ptr`/`CStr` arguments (`MTy`,
  `Callee::Rt` in `src/mir/llvm/codegen.rs`), so new codegen is mostly marshalling.

## 2. Surface

A package (or project) that declares `effects = ["ffi"]` may declare `extern fn`. The symbol string
is a **C prototype**. Models already write C prototypes reliably, and the prototype gives the exact
widths, which Auk's own types (`int` = i64) don't:

```auk
pub extern fn open(path: str, db: ffi.Ptr, flags: int, vfs: ffi.Ptr): int =
    "int sqlite3_open_v2(const char *, sqlite3 **, int, const char *)"
extern fn column_text(s: ffi.Ptr, col: int): str? = "const unsigned char *sqlite3_column_text(sqlite3_stmt *, int)"
```

The compiler checks each Auk type against its C type. A mismatch is a new error, E0040.

| C type | Auk type | marshalling |
|---|---|---|
| `char short int long long long int8_t..int64_t size_t ssize_t` and their `unsigned` forms | `int` | truncate going in; sign- or zero-extend coming out |
| `bool` / `_Bool` | `bool` | |
| `double` / `float` | `float` | `float` converts |
| `const char *` (param) | `str` | temporary NUL-terminated copy, freed after the call |
| `const char *` (return) | `str` or `str?` | copied; NULL → `none` (`str` panics on NULL) |
| any other `T *`, `void *` | `ffi.Ptr` | passed through |
| `void` (return) | `()` | |

Not supported in v1: structs by value, variadic functions (`...`), and callbacks from C into Auk.
Each one gets a clear error.

Every user extern implicitly `uses ffi`, so callers must declare `ffi` too. The effect then shows up
in `raft` dependency audits, which is where a reviewer should see it.

## 3. The core `ffi` module (`compiler/prelude/ffi.auk`, `runtime/src/ffi.rs`)

`ffi.Ptr` is a plain machine address. It isn't reference-counted or freed automatically, can be
compared, and `"{p}"` prints it in hex. Helpers (all `uses ffi`):

- `ffi.null`, `p.is_null()`, `p.offset(n)`
- `ffi.alloc(bytes): Ptr` (zeroed), `ffi.free(p)`
- `p.read_i32(off) read_i64 read_u8 read_f64 read_ptr`, and `write_*` for each
- `ffi.cstr(p): str` (copy up to NUL), `ffi.bytes(p, n): [int]`, `ffi.from_bytes(xs): Ptr`
  (malloc'd; the caller frees it)

That's enough for out-params (`sqlite3 **`), blobs and C strings, and keeps C memory explicit.

## 4. Linking

`raft.toml`:

```toml
[link]
libs = ["sqlite3"]
```

- raft validates the table. The compiler's manifest reader gathers `libs` across the whole
  dependency graph.
- **JIT** (`run`, `test`, the REPL, `--live`, `--debug`): `dlopen` each lib (`lib<name>.dylib` /
  `.so` / `.so.<N>`, `RTLD_GLOBAL`) before compiling. Then `dlsym` each user-extern symbol into
  `JITBuilder::symbol`. A missing library or symbol is a compile error that names it and gives an
  install hint.
- **`auk build`**: add `-l<name>` per lib.

## 5. Safety

C code can crash the process. `catch`/`sup` don't contain a segfault, and the spec will say so.
The `ffi` effect is how that risk shows: a package that uses it says so in its manifest, and every
caller has to declare `ffi` as well. The leak checker doesn't see C allocations.

## 6. Phases

1. **Core FFI.** Parser gate on the `ffi` effect (E0036 rewritten), the C-prototype parser, the
   type check (E0040), marshalling in lowering, the `ffi` module and runtime helpers. Tested
   against libc symbols already in the process (`strlen`, `abs`, `getenv`), in both
   the JIT and `auk build`.
2. **Linking.** The `[link]` table in raft and the compiler, `dlopen`/`dlsym` for the JIT, and
   `-l` for build. Tested by calling `libz` or `libsqlite3` (system libraries on macOS; Linux
   needs the dev package, and CI skips those tests if it's missing).
3. **`sqlite` package.**
   - The API: `open`/`close`, `exec`, `prepare`/`bind`/`step`/`rows`, typed columns (a
     `Col` enum: `Null Int Float Text Blob`), `query(sql, params): [[Col]]!`, `transaction`, and
     an `Error` enum built from the sqlite result codes.
   - Handles are closed explicitly: Auk has no user destructors. `sqlite.with(path, fn(db))`
     closes on every path.
   - A README, and tests under `AUK_LEAK_CHECK=1` using `:memory:`.
4. **Docs and tooling.** The FFI section in spec.md, E0036/E0040 docs, a raft.md `[link]` entry,
   the packages-next log, LSP hover for C prototypes, `auk fmt` passthrough.

## 7. Open questions

- Automatic close: a drop hook for structs that wrap an `ffi.Ptr` would make leaks impossible.
  It's left out of v1 because it's a language feature in its own right.
- Windows: `LoadLibrary`, and `.lib` vs `.dll` naming at link time. Same shape, done after macOS
  and Linux.
