# Plan: Auk on Windows

**Goal:** `auk` and `raft` run natively on Windows (x86-64 first, arm64 later): every command,
the integration tests, a Windows bootstrap seed, and CI on GitHub's Windows runners — the same bar
as macOS and Linux (docs/self-host-plan.md, Phase 6).

**Where we start:** nothing is Windows-aware. The runtime (`runtime/c`, ~14k lines) is POSIX:
pthreads in 12 files, `setjmp`/`longjmp` for `catch`, signals and `sigaltstack` for stack
overflow and crash traces, `fork` in tests, `posix_spawnp`/pipes/`poll`/sockets/`dlopen` in
`core.c`, Network.framework or OpenSSL in `tls.c`. The compiler (`compiler/src`) calls POSIX
through `ffi` directly: `posix.auk` (`fork`, `waitpid`, `dup2`, `_exit`), `debug.auk` (Unix
sockets, `poll`, pipes, `posix_spawnp`, signals), `hatch.auk`/`mcp.auk` (`posix_spawnp`,
`waitpid`, `kill`), `live.auk` (`fork`, `stat` at hard-coded offsets), `paths.auk` (`realpath`,
`uname`), `orcjit.auk` (`dlopen`), `native.auk` (`cc`, `-export_dynamic`, `dsymutil`). The
JIT finds the runtime in its own process through `dlsym`.

**Why there is no shortcut:** Auk has no conditional compilation, and an `extern fn` bound to
`fork` must resolve when the program links, so the compiler can't simply skip POSIX calls on
Windows. And no `auk` runs on Windows (`v0-rust-final`'s runtime is the same POSIX C), so the
first Windows seed has to be **cross-compiled** from Linux.

**Rule:** as in the self-host plan, one moving part at a time; macOS and Linux stay green
(`scripts/check.sh`, the fixed point, CI) after every step.

---

## W0 — Decisions (short)

- **Target:** `x86_64-pc-windows-msvc` (the MSVC ABI, UCRT), compiled with clang, linked with
  `lld-link`. Not MinGW: the system's ABI, debuggers and DLLs are MSVC's, and LLVM ships both
  tools. The Windows SDK and UCRT import libraries come from Visual Studio Build Tools (present on
  GitHub's runners) or `xwin` (for cross-linking from Linux).
- **LLVM's C API:** the official Windows LLVM release ships `LLVM-C.dll`/`LLVM-C.lib` (the C API
  as one DLL) but no `llvm-config`; `packages/llvm` gets a `[link] windows` entry naming it
  (`${LLVM_DIR}`).
- **Build script:** `build.sh` under Git Bash (on every GitHub runner and every Git for Windows
  install) at first; a `build.ps1` only if that proves fragile.
- **Text at the OS boundary:** the runtime's API stays UTF-8; it converts to and from UTF-16 in
  the Windows calls (`*W` functions), and sets the console to UTF-8.

## W1 — One OS layer (on macOS and Linux, before any Windows code)

The groundwork that makes the rest possible, done and checked on the platforms we have:

- [ ] **Threads and sync shim** `runtime/c/os_thread.h`: mutex, condition variable (with a
      timeout), once, thread create/join, thread-locals (`_Thread_local` works in clang on
      Windows), sleeps. Every `pthread_*` in the runtime goes through it; POSIX first.
- [ ] **The compiler's OS calls move into the runtime** (`runtime/c/os.c`, `AUK_API auk_os_*`):
      start a child with redirected streams, in its own process group or job, with an
      environment; wait with a timeout; kill a process tree; pipes; `poll` over pipes and
      sockets; Unix-socket connect/listen (Windows 10 has `AF_UNIX`); file modification times
      (replacing `live.auk`'s `stat` offsets); `realpath`; the OS and architecture; the last error
      code; `_exit`. `posix.auk` becomes `os.auk` over these, and `debug.auk`, `hatch.auk`,
      `mcp.auk`, `live.auk`, `paths.auk`, `orcjit.auk` and `tests/runner/src/sys.auk` use it.
      Every `diff`, golden and runner result unchanged.
- [ ] **No `fork` in the compiler's design:** today `auk test` runs each file of a flat directory,
      imprint helpers, `dive` inputs and `run --live` children in forked children that inherit
      the JIT. On Windows a child is a new process: `auk __jit run|test` (it exists, with
      `AUK_SOURCES`) and a new `auk __imprint`. Keep `fork` on POSIX (it is faster); put both
      behind one `os.run_child` so the Windows path is exercised on POSIX too
      (`AUK_NO_FORK=1` in CI).
- [ ] **`testing.c`'s per-test `fork`** (isolating a crashing test): the same treatment, a child
      process per test where `fork` is missing.

## W2 — The runtime on Windows

Each module built with clang for the MSVC target and its C tests passing (`runtime/c/test`, run
under Git Bash or a `.ps1`):

- [ ] `os_thread.h` on Win32: `SRWLOCK`, `CONDITION_VARIABLE`, `InitOnceExecuteOnce`,
      `CreateThread` with a stack size (the 256 MB main-stack thread), `SleepEx`.
- [ ] **`catch` (the spike, do it first):** `setjmp`/`longjmp` under the MSVC ABI unwind through
      every frame with `RtlUnwindEx`, which needs unwind tables (`.pdata`/`.xdata`) for JIT-ed
      code and LLVM-generated frames. Options: register ORC's unwind info (LLVM's COFF platform
      support), or use LLVM's `__builtin_setjmp`/`__builtin_longjmp` (no unwinding; our frames
      have no destructors). Prototype both against `catch` across JIT code, tasks and the
      debugger before porting further.
- [ ] Stack overflow (`stack.c`): a vectored exception handler for `EXCEPTION_STACK_OVERFLOW`,
      the guard page reset with `_resetstkoflw`, the same "stack overflow" panic. Crash traces
      (`trace.c`): the same handler for access violations.
- [ ] `core.c`: files and directories (`CreateFileW`, `FindFirstFileW`), processes
      (`CreateProcessW`, anonymous pipes, `PATHEXT` lookup), environment
      (`GetEnvironmentStringsW`, case-insensitive names), time (`QueryPerformanceCounter`,
      `GetSystemTimePreciseAsFileTime`), sockets (Winsock 2, `WSAStartup` once, `WSAPoll`),
      terminals (`GetConsoleMode`).
- [ ] `tls.c`: OpenSSL 3 loaded with `LoadLibrary` (as `dlopen` on Linux) first; SChannel (the
      system's TLS, like Network.framework on macOS) after.
- [ ] `dbg.c`: its socket over Winsock `AF_UNIX`; thread suspension as on POSIX (cooperative).
- [ ] `ffi.c`, `orcjit`'s symbol lookups: `LoadLibraryW`/`GetProcAddress`.
- [ ] `gui`, `gui_host`, `pixels`, `audio_out`: fail cleanly as on Linux (`gui.open` returns an
      error); Win32 windows and WASAPI are a later, separate project.

## W3 — The compiler targeting Windows

- [ ] A target, not just the host: `AUK_TARGET`/`--target` picks the triple and data layout (the
      host's by default), so Linux can cross-compile for Windows (needed for the first seed).
- [ ] The Win64 C ABI in `mir/layout.auk` (`c_pass`: aggregates over 8 bytes by reference, no
      register pairs) next to SysV and AArch64; `long` is 32-bit in `cffi.auk`'s C types.
- [ ] Objects are COFF; `native.auk` links with `lld-link` (`AUK_LINKER`), `/SUBSYSTEM:CONSOLE`,
      UCRT and the system libraries (`ws2_32`, `bcrypt`, `kernel32`), adds `.exe` to `-o`.
- [ ] The runtime's symbols visible to `ffi.symbol` and the JIT: the runtime as a DLL
      (`auk_rt.dll`, exports from `AUK_API`) or `/EXPORT`s from the executable; decide in W2's
      spike.
- [ ] `-g`: CodeView instead of DWARF (`dwarf.auk` sets the module flag; LLVM's DIBuilder emits
      either), a `.pdb` from `lld-link /DEBUG` instead of `dsymutil`.
- [ ] ORC on COFF: LLJIT with the COFF platform, SEH tables registered (from W2's spike).

## W4 — Paths, text and processes everywhere

- [ ] `paths.auk` (compiler and raft): `\` and `/`, drive letters, UNC paths, case-insensitive
      comparisons where the file system is, `GetFinalPathNameByHandleW` for `canonicalize`.
- [ ] CRLF in sources (the lexer already accepts it) and in tool output; stdin/stdout in binary
      mode for `lsp`, `mcp` and `dap` (no newline translation).
- [ ] Executables: `.exe` lookup on `PATH` (`;`-separated), `auk build -o x` writes `x.exe`.
- [ ] `raft`: paths in `raft.lock` stay `/`-separated (lock files identical across platforms).

## W5 — Tools

- [ ] `debug`/`dap`: child via `os.run_child`, Ctrl-C with `SetConsoleCtrlHandler`, killing the
      program's tree with a job object.
- [ ] `live`: file watching by modification time (as now); `ReadDirectoryChangesW` later.
- [ ] `hatch`, `mcp`, `dive`, `lsp`: through the OS layer; nothing Windows-specific beyond W1/W4.

## W6 — Bootstrap and CI

- [ ] **The first Windows seed, cross-compiled:** (1) a Windows runner builds the runtime with
      clang (no `auk` needed) and uploads `auk_rt.lib` + `auk_rt.bc`; (2) a Linux runner builds
      `compiler/` with `AUK_TARGET=x86_64-pc-windows-msvc AUK_EMIT_BC=…`, embedding that runtime,
      linked with the runtime's bitcode: `seed/windows-x86_64.bc.gz`; (3) the Windows runner
      compiles and links it (`clang`, `lld-link`, `LLVM-C.lib`) and runs `build.sh --check
      --test` from it. After that, `scripts/cut_seed.sh` works on Windows like anywhere else.
- [ ] `.github/workflows/auk.yml`: a `windows-2025` row in `ci`, and the cross-seed job.
- [ ] The integration tests on Windows: `tests/runner/src/sys.auk` through the OS layer; audit
      expected outputs for `/` paths and `\n`, and tests that shell out (`sh`, `cc`); skip the
      macOS-only ones (GUI) as on Linux.

## Risks

- **`catch` across JIT frames** under the MSVC ABI (W2's spike decides the approach; it can touch
  codegen if landing pads turn out to be the answer — the same question as Phase 7b).
- **ORC JIT on COFF** is less used than on Mach-O/ELF: unwind registration, TLS in JIT-ed code,
  symbol lookup in the executable.
- **No `fork`:** children re-compile instead of inheriting the JIT; `auk test` over a flat
  directory and imprints get slower on Windows. Measure; cache compiled objects if needed.
- **Process spawning cost** (and antivirus scanning new executables) slows the integration tests.
- **The SDK:** linking needs the Windows SDK/UCRT libraries (Build Tools, or `xwin` on Linux);
  document what a fresh machine needs.

## Rough sizing

| Step | Work | Size |
|---|---|---|
| W0 | decisions | S |
| W1 | OS layer, no `fork` in the design (on macOS/Linux) | M |
| W2 | runtime on Windows (`catch` spike first) | L |
| W3 | compiler targets: triple, Win64 ABI, COFF, lld-link, CodeView, ORC | L |
| W4 | paths, text, processes | M |
| W5 | tools | S–M |
| W6 | cross seed, CI, tests | M |
