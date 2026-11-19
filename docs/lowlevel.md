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

`raw.setjmp(buf: raw.Ptr<raw.JmpBuf>): bool` and `raw.longjmp(buf): never` are libc's
`_setjmp`/`_longjmp` (no signal mask, no unwinding). **Differs from the decision above** (as
implemented, 2026-11-18): LLVM's `llvm.eh.sjlj.setjmp`/`longjmp` are lowered to nothing on
AArch64 (`llc` turns the setjmp into `mov w0, wzr` and the longjmp into a `nop`; clang rejects
`__builtin_setjmp` there), so the dialect calls libc instead, the call marked `returns_twice`.
`raw.JmpBuf` is 320 bytes, enough for every supported platform's `jmp_buf`. A function that
calls `raw.setjmp` is compiled `optnone noinline`, so its locals hold their last values after
the jump back (C's `volatile` rule, without `volatile`). `catch.c` becomes `catch.auk` with the
same frames and semantics; generated code
still calls `auk_catch(thunk, env, out)`. The one rule (as now): only the catch module uses them.
The stack-overflow handler (`stack.c`: `sigaltstack` + `SIGSEGV`) jumps to the same recovery
points; a signal handler is an `export fn` passed to `sigaction`.

## 7a. As implemented (Phase 7a): what differs, and the details the sections above leave open

- **`raw.setjmp`/`raw.longjmp`** are libc's `_setjmp`/`_longjmp` (§7), not the sjlj intrinsics.
- **`raw thread var` needs compiled code:** the JIT (`auk run`, `auk test`) links without a
  platform runtime and has no thread-local storage, so it refuses a program with one; `auk
  build` and `auk build --lib` use LLVM's default (general-dynamic) TLS model, which Mach-O
  lowers to TLV descriptors and ELF to `__tls_get_addr` (relaxed by the linker in an
  executable). The runtime itself is never JIT-compiled (`auk` links it), so this costs nothing.
- **Types:** there is no `f64` (it is `float`, as §2 says); `isize`/`usize` are their own types
  (64-bit). An integer literal takes the fixed-width type its context expects (`x + 1`,
  `let b: u8 = 250`; it must fit); a literal on the left of an operator whose right side is
  fixed-width does not (write `x + 1`, not `1 + x`). Shift amounts are taken modulo the width.
  Integer `/` and `%` by zero trap; `f32` has `%` (`frem`). A string literal (no
  interpolation) where a `raw.Ptr<u8>` is expected is a C string: a private constant,
  NUL-terminated (`auk__panic3(loc, "expected Int, got ", …)`, `fn name(): raw.Ptr<u8> = "Int"`).
- **Ordinary functions of the runtime package may hold raw values** (fixed-width numbers, raw
  structs, pointers) without `uses raw`; only the intrinsics (and `extern var`s) need the
  effect, and the E0419 rule (no reference-counted type) applies to `uses raw` functions and
  `export fn`s.
- **Intrinsic signatures:** `p.at(i)`, `p.offset(i)`, `raw.from_int(n)` and the byte counts of
  `copy`/`move`/`fill`/`compare`/`alloc`/`realloc` take any integer type (`int` or fixed-width).
  `raw.cast<U>(x)` takes a `raw.Ptr`, `raw.Fn`, `ffi.Ptr` or C `extern type` and gives a
  `raw.Ptr<U>`, or, when `U` is a `raw.Fn`, that function pointer itself (§10's
  `raw.cast<raw.Fn<(raw.Ptr<()>, bool) => ()>>(complete.invoke)(complete, ok)`); without `<U>` it
  is what the context expects (`let f: raw.Fn<…> = raw.cast(p)`, `let q: raw.Ptr<T> =
  raw.cast(p)`). So a pointer to function pointers is written by its type: `let slots:
  raw.Ptr<raw.Fn<…>> = raw.cast(p)`. `is_null` works on `raw.Ptr`
  and `raw.Fn`; `raw.null()` is a `raw.Ptr`. `p.int()` is declared `fn int <T>` in the prelude
  (a space: `int<` would read as a unit of measure). A `raw.Fn` value is called like a function
  (`f(x)`), a global one of the module too (`raw var hook: raw.Fn<…>`, `hook(x)`); calling one
  stored in a struct field, or another module's global, needs it in a local first.
- **Explicit type arguments** are written only after `raw.` (`raw.size_of<T>()`): the parser
  reads `raw.name<` with no space before `<` as type arguments, so ordinary comparisons are
  untouched. `.f` (a field selector) is an argument form only.
- **Constants:** initializers of `raw var`/`raw thread var`/`export var` and `raw let`, and
  `raw assert`, are evaluated by the checker: literals (an integer literal must fit the type
  expected, E0210 as for a local; arithmetic wraps), other `raw let`s of the module and `pub
  raw let`s of other modules (`facts.PTHREAD_MUTEX_INITIALIZER`),
  `raw.size_of/align_of/offset_of`, `raw.null()`, conversions, arithmetic, comparisons, raw
  struct literals (missing fields are zero), fixed array literals (`[raw.fn_of(f), raw.fn_of(g)]`
  for a `[raw.Fn<…>; 4]`: missing elements are zero), and addresses: `raw.addr_of(&g)` of a
  `raw var`, `export var` or `extern var` (any order, its own address included; another
  module's by path if `pub`; not a `raw thread var` or a `raw let`), `raw.fn_of(f)` of a
  non-generic function named directly or by path (as `raw.fn_of` allows it anywhere), and `raw.cast` of either (to the type
  argument, or the type expected). They become relocations, so a global block literal (§10) or
  a table of function pointers costs nothing at startup (and an `auk build --lib` object
  exports one as data). A `raw let` holding addresses is a value like any other: the
  addresses are taken where it is used. A raw struct literal anywhere may leave fields out
  (they are zero); a `raw union` literal gives at most one field.
- **`extern var name: T = "symbol"`** declares C data (no initializer); reading it, writing it
  and `raw.addr_of(&name)` need `uses raw` (E0410).
- **`export fn`:** one clause, no type parameters, raw types only (E0419); C's calling
  convention as `mir/layout.auk` classifies it (below); external linkage under its own name, so dead-code elimination keeps
  it; `inline export fn` is the same plus `inlinehint`. `raw.fn_of(f)` takes an `export fn`, or a
  function whose parameters and result are numbers, `bool` and raw pointers.
- **`auk build --lib [--bc] <file> -o <out>`** writes an object (or bitcode) at O2 with every
  function of the program, the `export fn`s and `export var`s external, no `main` and nothing
  run at startup (a library with string literals or top-level `let`s is refused). The runtime's
  bitcode isn't linked into it. Raw globals are internal (`raw var`) or thread-local, so
  `rtlink` treats the functions that touch them exactly as it treats C statics and
  `_Thread_local`s: never copied into programs.
- **FFI:** in the runtime package a C prototype may take function pointers (`int (*f)(int)`),
  matched by `raw.Fn` (or `void *`); `raw.Ptr` is any `T *`, a fixed-width integer a C integer of
  its width, `f32` `float`, a raw struct a C `struct` by value.
- **The C ABI of raw structs by value** (`mir/layout.auk`, what clang emits; tested both ways
  against `cc` by `runtime/test/raw/cabi.auk`): on x86-64 (SysV) each eightbyte of an aggregate
  of at most 16 bytes is SSE when it holds only floats (two `f32`s travel as the bits of one
  double, the register clang's `<2 x float>` uses; one `f32` and padding as a `float`), else
  INTEGER (`{float, i64}` is xmm + general register); bigger aggregates are `byval` (and
  returned through `sret`), as is one whose eightbytes don't all fit in the registers left (6
  general, 8 SSE). On AArch64 a homogeneous floating-point aggregate (1-4 `f32`s or 1-4
  `float`s, arrays and nested structs included) is `[n x float]` in consecutive SIMD
  registers, other aggregates up to 16 bytes `[2 x i64]` (both registers or both on the stack),
  bigger ones a pointer to a copy.
- **Error codes:** E0418 (the gate), E0419 (a reference-counted type in `uses raw` code, an
  `export fn` or a raw struct), E0421 (not a compile-time constant, a failing `raw assert`, a
  non-constant or invalid memory order).
- **Targets (§11):** in the runtime package, `src/x.<os>-<arch>.auk`, `src/x.<os>.auk` and
  `src/x.auk` are variants of the module `x`; the loader takes the most specific one for the
  host (`<os>` is `macos`/`linux`, `<arch>` `arm64`/`x86_64` as `uname -m` normalizes), and
  ignores the others (other packages keep reading `a.b.auk` as the module `a.b`). There is no
  cross-compilation yet, so "the target" is the machine running `auk`. The variants' public
  items aren't compared yet. `raw.add_overflow/sub_overflow/mul_overflow(a, b): (T, bool)`
  (`llvm.{s,u}{add,sub,mul}.with.overflow` by `T`'s signedness), `raw.ctz`/`raw.clz` (the width
  for 0), `raw.popcount`, `raw.bswap` (16 bits and wider) take `int` or a fixed-width integer.
- **No TBAA:** codegen attaches no alias metadata (none anywhere), so `raw.cast`
  reinterpretation and reading a union through another field are well-defined.

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

## 11. Targets: per-OS code and the C headers' facts

The runtime chooses by OS and CPU in 30 places (`#if`), and needs what C headers provide
(docs/runtime-port.md, "Gaps"). No conditional compilation in the language; instead:

- **Per-target files** (`raw` packages only): beside `os.auk` a module may have `os.macos.auk`,
  `os.linux.auk`, `os.linux-arm64.auk`, … The resolver loads the most specific one matching the
  target (`<os>-<arch>`, then `<os>`, then the plain file), and only that one; all variants must
  declare the same public items (checked when the variants are compiled for their targets, and by
  CI on each platform). Like Go's `_linux.go`.
- **The headers' facts, generated:** `runtime/gen/cfacts.sh` compiles a small C program on a
  platform that prints the constants and layouts the runtime uses (`O_*`, `F_*`, `SIG*`, `E*`,
  `SO_*`, `AF_*`, the `W*` status tests as functions, `PTHREAD_*_INITIALIZER` bytes, `struct stat`,
  `sigaction`, `sockaddr_*`, `msghdr`/`cmsghdr`, `pthread_*_t` sizes, `ucontext` register offsets)
  as `runtime/src/cfacts.<os>-<arch>.auk`: `raw let`s and `raw struct`s, checked in. While the C
  runtime exists, `raw assert`s compare them with the headers at build time. A new platform runs
  the script once.
  **As implemented** (2026-11-18): `runtime/gen/cfacts.sh` compiles `runtime/gen/cfacts.c` with
  the platform's `cc`; the files for `macos-arm64`, `linux-arm64` and `linux-x86_64` are checked
  in (the last two made in `ci/linux`'s image, `--platform=linux/amd64` for x86-64). Besides
  `raw let`s and `raw struct`s (padding as `_pad<n>` fields, every offset a `raw assert` of the
  value C printed), a file holds the opaque types as words of their alignment (so
  `PTHREAD_*_INITIALIZER` are raw struct literals), `HAS_X` flags for the optional constants,
  and the per-OS code §11 leaves to "small raw functions": `uc_pc`/`uc_sp`/`si_addr`, the `W*`,
  `S_IS*` and `CMSG_*` macros, `errno()`, `stdout()`/`stderr()` (so no `os.*.auk` is needed for
  them). The comparison with the headers is `runtime/test/abi/run.sh` (a `--lib` probe linked
  with C), not a build-time step; it also checks that the files declare the same items above
  their "only on <os>" part (macOS: `DISPATCH_TIME_*`; Linux: the ELF structs). The shared
  types of `auk_rt.h` are `runtime/src/abi.auk`, checked the same way. docs/runtime-port.md
  lists what each holds and what's left out.
- **`errno` and C's macros over functions:** `errno` is `os.errno()` per OS (`*__error()` on
  macOS, `*__errno_location()` on glibc); `stdout`/`stderr` are `extern var`s (`__stdoutp` /
  `stdout`) in the per-OS files; `CMSG_*`, `S_ISDIR`, `WIFEXITED`… are small `raw` functions over
  the facts.
- **Bit and overflow intrinsics:** `raw.add_overflow(a, b): (T, bool)` (and `sub`, `mul`:
  `llvm.s/uadd.with.overflow`), `raw.ctz`, `raw.clz`, `raw.popcount`, `raw.bswap`.
- Function-local statics become module-level `raw var`s; `_Static_assert`/`offsetof` are
  `raw assert` and `raw.offset_of`.
