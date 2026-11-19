# Porting the runtime to Auk: the checklist

docs/self-host-plan.md, Phase 7; the target is the `raw` dialect, docs/lowlevel.md. This is
what each file of `runtime/c` needs from the dialect, and what does not translate line by line.
Measured 2026-11-18 (the C after "Write C that will translate to Auk later" was enforced).

## The rules the C now keeps (lowlevel.md, section 9)

- **No varargs calls** except in `cwrap.c`: fixed-argument wrappers for `open`, `shm_open`
  (varargs on macOS), `fcntl` (int argument), `ioctl` (pointer argument) and `snprintf` of
  one double (`%.*e`, `%.*f`, `%g`). Each becomes one `extern fn` with a fixed prototype.
  Integers and hex are formatted without libc (`str.c`: `auk__fmt_i64`, `auk__fmt_u64`,
  `auk__fmt_hex`, `auk__sb_u64`, `auk__sb_hex`); messages are built with the string builder
  and then copied into a fixed buffer (`auk__sb_take_into`, cut as `snprintf` cut),
  duplicated (`auk__sb_take_cstr`) or written to stderr in one write (`auk__sb_eprint`).
  Checked with the clang AST (`-Xclang -ast-dump`: no `DeclRefExpr` to a function whose type
  ends in `...)` outside `cwrap.c`). The runtime's own API has no varargs.
- **No `goto`** (the last six were `gui_host.c`'s `show`, now early returns).
- **No macros** but three that have to be: the include guard, `AUK_API` (a marker that
  expands to nothing; `export fn` in Auk) and `stack.c`'s `_GNU_SOURCE` (a glibc feature
  switch). Constants are `enum`s or typed `static const`s (`AUK_MAIN_STACK`, `STACK_GUARD`...).
- **No bit-fields** (none were left).
- **Unions: three, all `raw union`s:** `AukValue.u` (`auk_rt.h`: bool / i64 / f64 / three
  pointers; the pilot module `value.c` uses it), and in `gui.c` the two control-message
  buffers of `send_msg`/`read_full` (`union { struct cmsghdr h; uint8_t b[N]; }`: the
  `cmsghdr` member is there only for alignment).

## What the dialect does not cover yet (decide before the port reaches these files)

1. **Conditional compilation.** 30 `#if`/`#elif` lines choose by OS (`__APPLE__`,
   `__linux__`), CPU (`__aarch64__`, `__x86_64__`), byte order (`audio_out.c`), or an optional
   constant (`SO_NOSIGPIPE`, `MSG_NOSIGNAL`). The dialect needs a compile-time `if` on the target (or
   per-OS files): `stack.c` (13), `core.c` (5), `gui.c` (5), `heap.c`, `audio_out.c`,
   `gui_host.c` (2 each), `tls.c` (1).
2. **C library macros and per-OS constants.** `errno` (a thread-local reached through
   `__error()` on macOS, `__errno_location()` on glibc), `stdout`/`stderr` (`__stdoutp` /
   `stdout` globals), `PTHREAD_MUTEX_INITIALIZER`/`PTHREAD_COND_INITIALIZER`/
   `PTHREAD_ONCE_INIT` (static initializers of opaque, per-OS layouts), `CMSG_*` (`gui.c`),
   `WIFEXITED`/`WEXITSTATUS`/`WIFSIGNALED`/`WTERMSIG` (`core.c`, `testing.c`), `S_ISDIR`
   (`core.c`), `ElfW`/`ELFMAG` (`stack.c`, Linux), and every `O_*`/`F_*`/`AF_*`/`SIG*`/`SO_*`
   value, which differ between macOS and Linux. Each needs a `raw let` per OS or a small C
   accessor.
3. **System struct layouts** as per-OS `raw struct`s: `struct sigaction`, `stack_t`,
   `ucontext_t`/`mcontext_t` (macOS `__ss.__pc`/`__rip`, Linux `pc`/`gregs`), `msghdr`/
   `cmsghdr`/`iovec`, `sockaddr_un`/`sockaddr_storage`/`addrinfo`, `stat`, `winsize`,
   `timespec`, and opaque-size buffers for `pthread_*_t`, `posix_spawn*_t`, `jmp_buf`.
4. **Importing a C global.** `environ` (`core.c`, `gui.c`), `stdout`/`stderr`; the dialect
   has `export var` but no `extern var`.
5. **Overflow-checked and bit intrinsics.** `__builtin_add/sub/mul_overflow` (`rc.c` for
   `int` arithmetic, `pixels.c`, `gui.c`, `gui_host.c`), `__builtin_ctzll`/`clzll`
   (`arr.c`). Raw integers wrap, so these need `raw.add_overflow(a, b): (T, bool)`-style
   intrinsics (LLVM's `*.with.overflow`, `cttz`, `ctlz`).
6. **Function-local statics** (`static` inside a function: `rc.c`, `core.c`, `gui.c`,
   `pixels.c` x2, `trace.c` x3) become module-level `raw var`s.
7. **`_Static_assert` / `offsetof`** (`auk_rt.h`, the layouts the compiler assumes):
   `raw assert` with `raw.offset_of`, as section 4 plans.
8. **`_Noreturn`** (panics, `auk__catch_throw*`): a `never` result.

## Per file

Lines are of the C today. "Globals" counts file-scope variables (thread-locals and atomics
among them); "callbacks" are function pointers handed to C or kept in tables.

| file | lines | needs from the dialect | not line-by-line |
|---|---:|---|---|
| `auk_rt.h` | 1013 | the shared `raw struct`s (header, str, arr, map, err, obj, task, frames; flexible array members `data[]`, `slots[]`), the one union (`AukValue`), 12 function-pointer typedefs (`raw.Fn`), `_Static_assert`s → `raw assert` | stays the C contract until the C is gone (lowlevel.md, section 8) |
| `value.c` | 239 | union `AukValue`, structs by value; nothing else (the pilot) | — |
| `err.c` | 125 | atomics (rc) | — |
| `copy.c` | 170 | atomics, callbacks (element copy ops) | — |
| `map.c` | 398 | callbacks (hash/eq/show ops), `const` tables | — |
| `arr.c` | 727 | callbacks (element ops, sort comparator), `ctz`/`clz` | — |
| `chan.c` | 168 | pthread mutex/cond (opaque layouts, initializers) | — |
| `heap.c` | 298 | 1 thread-local, atomics; `malloc_size` (macOS) / `malloc_usable_size` (Linux) | per-OS `#ifdef` |
| `catch.c` | 142 | 4 thread-locals (the recovery-point stack) | `sigsetjmp`/`siglongjmp`: replaced by `raw.setjmp`/`raw.longjmp` (LLVM sjlj, lowlevel.md section 7), not translated |
| `compiler.c` | 169 | 2 globals (the imprint file, its mutex), `FILE *` (`fputc`/`fwrite`) | — |
| `str.c` | 1556 | 2 thread-locals (show budget, debugger flag), atomics; `snprintf %.*e/%.*f` through `cwrap.c`; `strtod` | float formatting through libc is the 7b item "Ryu, Unicode tables → Auk" |
| `rc.c` | 792 | 4 globals (1 thread-local, 2 atomic), 1 function-local static, overflow builtins, `atexit` callback, `%g` through `cwrap.c` | — |
| `testing.c` | 309 | 4 globals, `fork`/`waitpid` and the `W*` status macros, `flockfile`, `stdout`/`stderr` | — |
| `task.c` | 467 | 6 globals (1 thread-local), atomics, `pthread_create` callback | — |
| `pixels.c` | 446 | atomics, 2 function-local statics, overflow builtins | — |
| `ffi.c` | 298 | `dlsym`; values through `raw.Ptr` | — |
| `core.c` | 1116 | 5 globals + 1 function-local static, `environ` (extern global), `qsort` callback, sockets/`getaddrinfo`/`posix_spawnp` structs, `S_ISDIR`, `W*` macros; `fcntl`/`ioctl`/`open` through `cwrap.c` | 5 `#if`s (OS, `SO_NOSIGPIPE`, `MSG_NOSIGNAL`, `arc4random_buf`/`getrandom`) |
| `trace.c` | 668 | 20 globals (5 thread-locals), 3 function-local statics, `sigaction` + `atexit` callbacks, `open` through `cwrap.c` | its fatal-signal handler re-raises with `signal(sig, SIG_DFL)`: fine as an `export fn` |
| `stack.c` | 376 | 3 thread-locals, `pthread_once`/`pthread_create` callbacks, `sigaltstack` | **the signal handler edits the interrupted context** (`ucontext_t` PC/SP per OS and CPU, 13 `#if`s) to return into `overflow_resume`; per-OS/arch `raw struct`s for `mcontext`, Linux ELF `.symtab` reading (`ElfW`) |
| `dbg.c` | 2141 | 50 globals (5 thread-locals, atomics), `pthread_key_create` destructor, `pthread_create`, `atexit`, `signal(SIGINT)` callbacks, Unix sockets | — (largest file; translate last among the plain ones) |
| `audio_out.c` | 328 | 6 globals (`dlsym`'d function tables: `raw.Fn` fields), `pthread_once` | per-OS `#if` (AudioToolbox / PulseAudio) and a byte-order `#if` |
| `gui.c` | 1301 | 26 globals, 2 `raw union`s (cmsg buffers), `CMSG_*`, `environ`, `posix_spawn` (+ the macOS `_np` call), `mmap`/`shm_open` (through `cwrap.c`), overflow builtins | 5 `#if`s (OS, `SO_NOSIGPIPE`) |
| `gui_host.c` | 1661 | 11 globals, 22 typed `objc_msgSend` wrappers (`raw.Fn` casts, as today: no Objective-C source), CoreFoundation run-loop source callbacks, `dlopen`/`dlsym`, `mmap` | macOS only (`#if __APPLE__` around the whole host) |
| `tls.c` | 916 | OpenSSL side: 4 globals, a `dlsym`'d function table (`raw.Fn`), `pthread_once` | **Network.framework side: blocks** (8 block literals: state, receive, send, verify handlers) and dispatch queues/semaphores: needs the block-literal layout in Auk (self-host-plan 7b) or another TLS API; the one file built with `-fblocks` |
| `cwrap.c` | 52 | nothing: it is the C half of the varargs boundary | **stays C** (or becomes varargs FFI support in the compiler; self-host-plan 7b) |

### Non-translatable, in short

- `catch.c`: `sigsetjmp`/`siglongjmp` → `raw.setjmp`/`raw.longjmp` (a different mechanism with
  the same frames; lowlevel.md section 7).
- `stack.c`: rewriting the interrupted thread's registers from a signal handler; per-OS, per-CPU
  context layouts.
- `tls.c` (macOS): blocks and libdispatch.
- `cwrap.c`: calling C varargs functions.
- Everywhere: the `#if`s, the C library macros and per-OS constants, `environ` (items 1, 2, 4
  above).
