# The `auk` command line

One binary does everything: `auk <command> [options] <file> [args...]`. Packages are managed
by the separate [`raft`](raft.md) command.

| command | does |
|---|---|
| [`auk run`](#auk-run) | compile and run a program |
| [`auk test`](#auk-test) | run `test` blocks |
| [`auk check`](#auk-check) | type-check only |
| [`auk build`](#auk-build) | make a native executable |
| [`auk fmt`](#auk-fmt) | format source files |
| [`auk explain`](#auk-explain) | explain an error code |
| [`auk dive`](#auk-dive) | the interactive REPL |
| [`auk debug`](debugging.md#auk-debug) | the debugger |
| [`auk holes`, `auk hatch`](ai.md) | report and fill `??` holes |
| [`auk mcp`](ai.md#the-mcp-server) | tools for AI agents, over the Model Context Protocol |
| [`auk lsp`, `auk dap`](editors.md) | the language server and debug adapter, for editors |
| `auk spec` | print the compact language reference |
| `auk ir [--llvm] <file>` | print the compiler's intermediate code (`--llvm`: the LLVM IR) |
| `auk --version` | print the version |

A `<file>` inside a project (a folder with a `raft.toml` above it) is compiled as part of that
project, with its modules and dependencies. A file anywhere else is a program by itself.

## `auk run`

```console
$ auk run main.auk [args...]
```

Compiles the program in memory and runs it; no files are written. Arguments after the file go
to the program's `main(args: [str])`. The exit status is the program's: its `int` result, 1 for
an error returned from `main`, 101 for a panic.

| option | |
|---|---|
| `-O` | optimize fully. Slower to start, faster to run; use it for long computations |
| `--live` | swap in new code on every save while the program runs: [Live reload](live-reload.md) |
| `--trace=json` | log every call, return, error, `peek` and panic as JSON lines on stderr |
| `--trace=<file>` | the same, into a file |
| `--trace-limit N` | stop tracing after `N` events (default 10,000) |
| `--trace-core` | trace core library functions too |

By default `run` uses a few cheap optimizations so programs start fast. Contracts (`ensures`)
are checked, and `??` holes are allowed (reaching one is a panic).

## `auk test`

```console
$ auk test                    # the project in the current directory
$ auk test src/parser.auk     # one file
$ auk test . parse            # only tests whose name contains "parse"
```

Runs each `test` block in its own process and prints `ok` or `FAIL` per test and a summary.
The exit status is 1 if any test failed. A directory that is not a project (no `src/`) is
treated as a folder of independent programs: each file with tests is run in turn.

| option | |
|---|---|
| `--trace=json` | after each `FAIL`, print the last events of that test's execution trace |
| `--trace=<dir>` | write every test's full trace to `<dir>/<test>.jsonl` |

See [Tests](../language/testing.md#tests) for writing them and
[Testing and debugging](debugging.md) for traces.

## `auk check`

```console
$ auk check main.auk
$ auk check main.auk --json
```

Type-checks without generating code. It prints nothing and exits 0 when the program is
correct; otherwise it prints the diagnostics and exits 1. This is the fastest feedback loop,
and what editors and agents run on every change.

`--json` prints one object, for tools:

```json
{"file":"a.auk","ok":false,"diagnostics":[{"code":"E0200","severity":"error",
  "line":11,"col":16,"end_line":11,"end_col":20,
  "message":"expected `int`, found `str`","notes":[],"fixes":[],
  "explain":"auk explain E0200"}]}
```

Each entry of `fixes` is an edit, `{line, col, end_line, end_col, text}`, that applies the
compiler's suggested fix.

## `auk build`

```console
$ auk build main.auk -o app
$ ./app
```

Writes a native executable: fully optimized, with the runtime linked in statically, depending
only on the system's C library. Release builds differ from `run` in three ways:

- `ensures` contracts are compiled out (`requires` stays).
- `test` blocks are left out.
- A program that still contains a `??` hole is refused.

`-g` adds line tables for `lldb` and `gdb` (on macOS in `<out>.dSYM`).

## `auk fmt`

```console
$ auk fmt src/              # format files in place
$ auk fmt --check src/      # list files that would change; exit 1 if any
$ auk fmt - < in.auk        # stdin to stdout
```

There is one style and no options. Run `--check` in CI.

## `auk explain`

```console
$ auk explain E0400         # a page: what the error means, a wrong example, the fix, common causes
$ auk explain               # every code with its title
```

Every diagnostic has a stable code, and every code has a page. The pages are built into the
binary, so this works offline.

## `auk dive`

```console
$ auk dive
🦆> let xs = [3, 1, 2]
🦆> xs.sort()
[1, 2, 3] : [int]
🦆> fn sq(n: int): int = n * n
🦆> xs.map(x => sq(x))
[9, 1, 4] : [int]
```

The REPL takes definitions, statements and expressions, and prints each expression's value and
type. Commands start with a colon:

| | |
|---|---|
| `:type <expr>` | the type of an expression, without running it |
| `:items` | list the session's definitions |
| `:load <file>` | add a file's definitions |
| `:save <file>` | write the session as a formatted `.auk` file |
| `:reset` | forget everything |
| `:explain <code>` | explain an error code |
| `:help`, `:quit` | |

Each input is compiled natively and replays the session's earlier statements first, so
statements with effects (`rand`, `time`, files) run again on each input.

## Environment variables

| | |
|---|---|
| `AUK_LEAK_CHECK=1` | `run` and `test` fail if the program leaks runtime objects |
| `AUK_STATS=1` | programs print how many copy-on-write copies they made at exit |
| `AUK_NO_MOVES=1` | compile without moving locals at their last use (to rule moves out when chasing a bug) |
| `AUK_MOVES_LIMIT=n`, `AUK_MOVES_LOG=1` | compile with only the first `n` moves; print where each move is (bisecting a bad move) |
| `AUK_LINKER` | a C compiler driver (`cc`, `clang`) for `build` to link with, instead of calling the system linker directly |
| `AUK_HATCH_CMD` | the model command `auk hatch` runs (default `claude -p`) |
