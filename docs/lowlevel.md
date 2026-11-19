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

A C global defined elsewhere (libc, a framework) is `extern var`, the data counterpart of
`extern fn`: `extern var stack_block_isa: [u8; 0] = "_NSConcreteStackBlock"` (the C name; the
type says how it's read, `raw.addr_of(&stack_block_isa)` is its address). Needed for block
literals (§10: `_NSConcreteStackBlock`, `_NSConcreteGlobalBlock`) and Network.framework's
`_nw_content_context_default_stream`; reading or writing one is `uses raw`.

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
typed `raw.Fn`s, as `gui_host.c` does today), no blocks syntax (`^{ … }`: Network.framework's
blocks are hand-made raw structs, §10).

## 10. Blocks without -fblocks (Network.framework)

`tls.c` (macOS) is the runtime's one user of Clang blocks: Network.framework, Security.framework
and libdispatch take them as callbacks. A block is just a C struct with a function pointer in it
([Clang's Block ABI](https://clang.llvm.org/docs/Block-ABI-Apple.html)), so the dialect builds
them by hand from `raw struct`s and `raw.Fn`s; no compiler support. **Proven** (2026-11-18) by
`runtime/c/test/spike/blocks.c`, compiled with `-fno-blocks`, run by
`sh runtime/c/test/spike/blocks.sh`: a real TLS connection to `openssl s_server` (refused by the
system trust store, then accepted by a verify block that pins the test certificate), send,
receive, cancel, the TLS 1.2 fallback configure, and `dispatch_sync`/`dispatch_async` with each
kind of block; clean under ASan + UBSan and `leaks --atExit` (0 leaks), and every copy the
frameworks make is released (copy/dispose counts balance).

**Layout** (64-bit; what Clang emits today, checked with `-emit-llvm`):
```auk
raw struct BlockHdr {                // every block starts with this
    isa: raw.Ptr<()>,                // &_NSConcreteStackBlock or &_NSConcreteGlobalBlock
    flags: i32, reserved: i32,
    invoke: raw.Ptr<()>,             // raw.fn_of(f): f(block: raw.Ptr<B>, args…) -> R
    descriptor: raw.Ptr<()>,
}
raw struct BlockDesc { reserved: usize, size: usize, signature: raw.Ptr<u8>, layout: raw.Ptr<u8> }
raw struct BlockDescCD {             // when flags has BLOCK_HAS_COPY_DISPOSE
    reserved: usize, size: usize,
    copy: raw.Fn<(raw.Ptr<()>, raw.Ptr<()>) => ()>,   // (dst heap copy, src) after the memmove
    dispose: raw.Fn<(raw.Ptr<()>) => ()>,             // before the heap copy is freed
    signature: raw.Ptr<u8>, layout: raw.Ptr<u8>,
}
raw struct RecvBlock { h: BlockHdr, op: raw.Ptr<NwOp> }   // captures follow the header
```
- `size` is `raw.size_of` the whole literal (header + captures): `_Block_copy` memmoves that
  many bytes. `layout` is null; `reserved` fields are 0.
- **Flags:** `BLOCK_HAS_SIGNATURE = 1 << 30`, `BLOCK_HAS_COPY_DISPOSE = 1 << 25`,
  `BLOCK_IS_GLOBAL = 1 << 28`. A stack literal is `HAS_SIGNATURE` (`| HAS_COPY_DISPOSE`), a
  global one `IS_GLOBAL | HAS_SIGNATURE`. The low 16 bits (refcount, deallocating) and
  `BLOCK_NEEDS_FREE` (1 << 24) belong to the runtime: always 0 in a literal.
- **Signature:** nothing tls.c calls reads it (the spike also passes with no signature flag),
  but it costs one string; use Clang's C encodings: `v16@?0^{nw_protocol_options=}8` (configure),
  `v32@?0^{sec_protocol_metadata=}8^{sec_trust=}16@?<v@?B>24` (verify),
  `v20@?0i8^{nw_error=}12` (state), `v36@?0^{dispatch_data_s=}8^{nw_content_context=}16B24^{nw_error=}28`
  (receive), `v16@?0^{nw_error=}8` (send), `B40@?0^{dispatch_data_s=}8Q16r^v24Q32` (data
  applier), `v8@?0` (`dispatch_block_t`).
- `invoke`'s first parameter is the block itself (the address of whichever copy is running, not
  the literal): captures are read through it. Arguments follow with their C types (`bool` is C's
  `_Bool`).

**The three kinds**, all of which the spike uses:
1. **Global** (no captures: tls.c's TCP configure block): a `raw let` literal with
   `isa = &_NSConcreteGlobalBlock`. `_Block_copy` returns it unchanged, `_Block_release` ignores
   it; it lives forever.
2. **Stack** (plain captures: pointers, `bool`s): a local (or any scratch memory) with
   `isa = &_NSConcreteStackBlock`. A framework that keeps a block calls `_Block_copy`, which
   mallocs `size` bytes, memmoves the literal and refcounts the copy; the literal may die as soon
   as the call returns (the spike scribbles over and frees it right away). Without helpers the
   captures are copied as bits and own nothing: their lifetime is the caller's, as in tls.c.
3. **Stack + copy/dispose** (captures that own a reference): `copy` retains the captured object
   on the new heap copy, `dispose` releases it. The literal itself holds no reference; each copy
   holds one, so the captured object lives exactly as long as the framework keeps the callback,
   including one it drops without calling (a cancelled connection). This replaces tls.c's
   hand-counted `NwOp.refs = 2`.

**Per API** (what tls.c passes, what the framework does with it):

| API | block | captures | copied? |
|---|---|---|---|
| `nw_parameters_create_secure_tcp` (TLS configure) | `(nw_protocol_options_t)` | `t`, `fallback` | yes |
| ″ (TCP configure) | `(nw_protocol_options_t)` | none: global | — |
| `sec_protocol_options_set_verify_block` | `(metadata, sec_trust_t, complete)` | `t` | yes (runs later on `t.q`) |
| `nw_connection_set_state_changed_handler` | `(nw_connection_state_t, nw_error_t)` | `t` | yes; released after cancel |
| `nw_connection_receive` | `(dispatch_data_t, nw_content_context_t, bool, nw_error_t)` | `op` | yes; released after the call |
| `nw_connection_send` | `(nw_error_t)` | `op` | yes |
| `dispatch_data_apply` | `bool (region, offset, bytes, len)` | `op` | no (noescape) |
| `dispatch_sync` / `dispatch_async` | `()` | `t`, `out` | sync: no; async: yes |

The verify block's third argument, `complete`, is a block the framework made: call it as
`raw.cast<raw.Fn<(raw.Ptr<()>, bool) => ()>>(complete.invoke)(complete, ok)`.

**Pitfalls**
- **Clang enables blocks by default on Darwin**: a C file that must not use them needs
  `-fno-blocks` (`-fblocks` in `build.sh` is redundant there).
- **Without `__BLOCKS__` the SDK headers hide every block-taking declaration**, not only the
  callback setters: `dispatch_data_create` (its destructor is a block; pass null for
  `DISPATCH_DATA_DESTRUCTOR_DEFAULT`) and `NW_CONNECTION_DEFAULT_STREAM_CONTEXT` (the data symbol
  `_nw_content_context_default_stream`) too. Declare them yourself with `raw.Ptr<()>` for each
  block: the `extern fn`s the Auk port writes anyway.
- **The dialect needs C data symbols:** `_NSConcreteStackBlock`, `_NSConcreteGlobalBlock` (whose
  *addresses* are the `isa`s) and `_nw_content_context_default_stream` (whose *value* is the
  context). An `extern var name: T` declaration (address and load) covers them.
- A copy/dispose helper runs on whatever thread the framework releases on, possibly after the
  callback (or instead of it): helpers must be thread-safe (atomic refcounts) and must not touch
  the caller's stack.
- Never set the refcount bits or `BLOCK_NEEDS_FREE` yourself, and never `free` a block the
  framework gave you; `_Block_copy`/`_Block_release` (libSystem) if one must outlive the call.
- `dispatch_sync` and `dispatch_data_apply` don't copy, so a stack literal there needs no
  helpers even when its captures own something.

