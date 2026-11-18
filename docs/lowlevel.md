# Low-level Auk (`raw`): the dialect the runtime is written in

docs/self-host-plan.md, Phase 7a. The runtime (`runtime/c`, ~15k lines of C) moves to Auk. It
needs what ordinary Auk deliberately lacks: raw memory, C layouts, mutable globals, atomics, no
reference counting, and functions C calls by a fixed name. This document is the dialect: small,
explicit in every signature, and unavailable outside the runtime.

Decisions (2026-11-18): **gated by an effect**, `raw`, that only the runtime package may
declare; **`catch` stays a runtime call**, implemented with LLVM's sjlj intrinsics (no
unwinding; codegen unchanged); **the port is module by module**, C and Auk linked together.

## 1. The gate

- `raw` is an effect. A function that uses anything below says `uses raw`; a function calling it
  must too (the usual effect rules). A package may list `raw` in `raft.toml`'s `effects` only if
  it is the runtime package (`runtime/raft.toml`, `name = "auk_rt"`); anywhere else: E0418
  (new) "`raw` is only for the runtime". The declarations below (`raw struct`, `raw var`,
  `export fn`, …) are errors outside that package too.
- Ordinary Auk is unchanged. `ffi` keeps its meaning (`extern fn` with C prototypes).

## 2. Types

- **Fixed-width integers:** `i8 i16 i32 i64 u8 u16 u32 u64 usize` (and `isize`), `f32`; `int` is
  `i64`, `float` is `f64`. Arithmetic on them **wraps** (no overflow check, as C's unsigned and
  `-fwrapv`); division by zero traps. Conversions are explicit: `u8(x)`, `i64(b)` (truncate or
  extend, sign by the source type); `bool(x)` is `x != 0`.
- **`raw.Ptr<T>`**: an address of a `T`, no refcount, may be null. `raw.Ptr<()>` is C's
  `void *`. `ffi.Ptr` and `extern type`s convert with `raw.cast`.
- **`raw struct` / `raw union`:** C layout (natural alignment, declaration order), copied by
  value, never refcounted; fields of raw types only. A last field `data: [u8; ..]` is a flexible
  array member (no size; `p.data` is a `raw.Ptr<u8>` to its first byte).
  ```auk
  raw struct Header { rc: i64, kind: u32, flags: u32 }
  raw struct Str { h: Header, len_bytes: i64, len_chars: i64, is_ascii: bool, data: [u8; ..] }
  raw union ValueU { i: i64, f: f64, s: raw.Ptr<Str> }
  ```
- **Fixed arrays:** `[T; N]` inside raw structs and raw globals (C arrays; `jmp_buf`).
- **C function pointers:** `raw.Fn<(A, B) => R>`: called like a function, compared, null.
  `raw.fn_of(f)` gives the address of an `export fn` or a raw `fn` with C-compatible types.
- **Forbidden in `uses raw` functions:** every refcounted Auk type (`str`, lists, maps, closures,
  `Value`, ordinary structs and enums, `T?`/`T!` of those, tasks). So the compiler emits no
  retain/release, no copies, no heap objects in raw code: the **no-RC mode** is the type rule,
  not a separate switch. Raw code sees Auk objects only as `raw.Ptr<Str>` and friends, laid out
  by `raw struct`s that mirror today's `auk_rt.h`. `T?` of raw types and plain enums without
  payloads are allowed (by value).

## 3. Memory and pointers (`raw` module intrinsics, `extern fn … = "@raw_…"` in the prelude)

| | |
|---|---|
| `p.load()`, `p.store(v)` | read/write a `T` at `p` |
| `p.f`, `p.f = v` | a field of the raw struct/union `p` points at (no copy of the whole) |
| `p.at(i)`, `p.at(i) = v`, `p.offset(i)` | element `i` / the address of it (`i` in units of `T`) |
| `raw.addr_of(&x)`, `raw.field_addr(p, .f)` | the address of a raw local/global, of a field |
| `raw.cast<U>(p)`, `p.int()`, `raw.from_int<T>(n)` | pointer casts, to and from integers |
| `raw.null<T>()`, `p.is_null()` | |
| `raw.size_of<T>()`, `raw.align_of<T>()`, `raw.offset_of<T>(.f)` | compile-time constants |
| `raw.copy(dst, src, n)`, `raw.move(…)`, `raw.fill(dst, b, n)`, `raw.compare(a, b, n)` | `llvm.memcpy/memmove/memset`, `memcmp` |
| `raw.alloc(n)`, `raw.realloc(p, n)`, `raw.free(p)` | `malloc`/`realloc`/`free` (abort on failure, as `auk__xmalloc`) |
| `raw.unreachable()`, `raw.trap()`, `raw.likely(b)` | |

## 4. Globals, thread-locals, constants

```auk
raw var live_objects: i64 = 0                 // a mutable global (C `static`), raw types only
raw thread var catch_top: raw.Ptr<CatchFrame> = raw.null()   // `_Thread_local`
raw let HEADER_SIZE: usize = raw.size_of<Header>()          // a compile-time constant
raw assert raw.size_of<Str>() == 40           // a compile-time layout check (`_Static_assert`)
```
Initializers are constant expressions. Globals are module-private unless `pub`; `export var`
gives one a C symbol (the runtime's `extern` data in `auk_rt.h`: `auk_dbg_armed`, …).

## 5. Exported functions

```auk
export fn auk_str_len(s: raw.Ptr<Str>): i64 uses raw = s.len_chars
inline export fn auk_retain(p: raw.Ptr<()>): raw.Ptr<()> uses raw { ... }
```
- The C ABI (`layout.auk`'s classification, as FFI calls use: raw structs by value in and out),
  the symbol is the name exactly, never mangled or removed by dead-code elimination.
- `inline` marks small functions for the runtime bitcode `auk build` links into programs
  (today's inlinable C functions: `always_inline` is too strong; it is LLVM's `inlinehint`).
- Generated code keeps calling these by name, so the compiler's declarations of runtime
  functions (`codegen.auk`, `intrin.auk`) are unchanged: C and Auk implementations are
  interchangeable, which is what lets the port go one module at a time.

## 6. Atomics and threads

- `raw.atomic_load(p, order)`, `atomic_store`, `atomic_swap`, `atomic_cas(p, old, new, ok_order,
  fail_order): (T, bool)`, `atomic_add/sub/and/or(p, v, order)`, `raw.fence(order)`; `order` is
  a constant of `raw.Order` (`Relaxed Acquire Release AcqRel SeqCst`). On integers and pointers.
- pthreads, `sigaction`, `mmap`, sockets, … are called as C functions: `extern fn` with
  prototypes, as ordinary FFI, extended to raw types (`raw.Ptr<T>` for any `T *`, fixed ints for
  C ints of their width, raw structs by value, `raw.Fn` for function pointers). A C callback
  (`pthread_create`'s start routine, `qsort`'s comparator) is `raw.fn_of(an_export_or_raw_fn)`.

## 7. `catch` (and the stack-overflow recovery)

`raw.setjmp(buf: raw.Ptr<raw.JmpBuf>): bool` and `raw.longjmp(buf): never` are
`llvm.eh.sjlj.setjmp`/`longjmp` (C's `__builtin_setjmp`: five words, no signal mask, no
unwinding). `catch.c` becomes `catch.auk` with the same frames and semantics; generated code
still calls `auk_catch(thunk, env, out)`. The one rule (as now): only the catch module uses them.
The stack-overflow handler (`stack.c`: `sigaltstack` + `SIGSEGV`) jumps to the same recovery
points; a signal handler is an `export fn` passed to `sigaction`.

## 8. What does not change

- The runtime's ABI: `auk_rt.h` stays the contract (generated code, the debugger, FFI), and
  `raw assert`s check the Auk layouts against it until the C is gone.
- `build.sh` builds `libauk_rt.a` and `auk_rt.bc` from C and Auk objects together
  (`auk build --lib`: an object, or bitcode, with the exported symbols and no `main`).
- Ordinary Auk programs: no new syntax reaches them, no codegen change.

## 9. Not in the dialect (on purpose)

No pointer arithmetic operators (`p + 1`: use `p.offset(1)`), no implicit integer conversions,
no varargs (call fixed-argument C wrappers), no `goto` (labeled `break`/`continue`), no macros
(constants and `inline` functions), no bit-fields (masks), no Objective-C (`objc_msgSend` through
typed `raw.Fn`s, as `gui_host.c` does today), no blocks until Network.framework needs them
(Phase 7b: `tls.c` is the one user of `-fblocks`).
