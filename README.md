# Auk

A statically typed language that compiles to native code with LLVM, designed so that code
(especially AI-written code) takes few tokens and is checked hard: clause functions with
exhaustiveness checking, errors and optionals in the types (`T!`, `T?`), declared effects
(`uses fs, net`), structural generics ("shapes"), units of measure (`9.81<m/s^2>`, checked at
compile time and erased at run time), contracts, and tests in the language.

```auk
enum Shape { Circle(r: float), Rect(w: float, h: float) }

fn area(Circle(r)): float = 3.14159 * r * r  // clauses: the compiler rejects gaps
fn area(Rect(w, h)): float = w * h

fn parse_side(s: str): float! {
  let x = float.parse(s) else fail("not a number: {s}")
  if x <= 0.0 { fail("sides must be positive") }
  x
}

fn main(args: [str]): int! {
  let sides = args.skip(1).map(a => parse_side(a))?  // the first error exits with 1
  let shapes = sides.map(s => Rect(s, s)) + [Circle(1.0)]
  for s in shapes {
    print("{s} has area {area(s):.2}")
  }
  0
}

test "area" { assert area(Rect(2.0, 3.0)) == 6.0 }
```

The language reference is [`docs/spec.md`](docs/spec.md) (also printed by `auk spec`). Runnable
programs live in [`examples/`](examples/): start with `hello.auk`, `fib.auk` and `tour.auk`.

## Usage

Install the latest release (macOS arm64, Linux arm64 and x86-64) into `~/.auk/bin`:

```sh
curl -fsSL https://auk-lang.org/install.sh | sh
```

(`AUK_VERSION=1.0.0` picks a release, `AUK_INSTALL=<dir>` the place.) Or build from source.

Requires LLVM 23 (`brew install llvm@23` on macOS; `llvm-23-dev` and `lld-23` from
apt.llvm.org on Linux) and the system linker: Apple's `ld` and the macOS SDK (the Command Line
Tools, `xcode-select --install`) on macOS; LLVM's `ld.lld` (or binutils' `ld`) and the C
library's development files (`libc6-dev`) on Linux. No C compiler: everything, the runtime
included, is Auk; only the tests of C interop compile C (`cc`). The compiler is written in Auk (`compiler/`);
`./build.sh` builds it from the previous `auk`, or on a fresh clone from the checked-in seed
(`seed/`: the compiler as LLVM bitcode), and installs `auk` and `raft` in `~/.auk/bin`.
`auk run`/`test` compile in memory (LLVM's ORC JIT); `auk build` also needs the linker.

```sh
./build.sh --check --test --install             # runtime, raft, auk (to the fixed point); tests
export PATH="$HOME/.auk/bin:$PATH"
auk run examples/tour.auk                       # compile and run
auk build examples/fib.auk -o fib               # native executable (release; refuses `??` holes)
auk check examples/calc.auk --json              # type-check only; JSON diagnostics for agents
auk test examples/bank.auk                      # run the `test` blocks (a file or a project dir)
scripts/check.sh                                # everything: build, tests, golden, bench
```

| command | does |
|---|---|
| `auk run <file> [args...]` | compile and run the program |
| `auk run --live <file> [args...]` | run, and swap in new code on every save: state, tasks and sockets survive; a type error keeps the old code; a changed struct/enum layout stops just the tasks that use it (their `sup` supervisors restart them on the new code), or restarts the program when `main` uses it. Try it on [`examples/live-site`](examples/live-site) |
| `auk run --trace=json\|<file> <file> [args...]` | run with an execution trace: every call (args shown), return value or error, `peek` and panic as JSON Lines (`json` = stderr) |
| `auk build <file> [-o out]` | compile to a native executable (release build; refuses `??` holes) |
| `auk check <file> [--json]` | type-check only; `--json` for machine-readable diagnostics with fix-its |
| `auk test [file\|dir] [filter]` | build and run the `test` blocks of a file, a project, or each file of a flat dir |
| `auk test --trace=json\|<dir> ...` | each FAIL line is followed by the last events of that test's trace (`json`), or every test's trace goes to `<dir>/<test>.jsonl`; `--trace-limit N` (default 10,000 events), `--trace-core` (also trace the core library) |
| `auk fmt [--check] <path>...` | format `.auk` files in place (`-` = stdin to stdout) |
| `auk holes <file> [--json]` | brief every `??` hole: expected type, variables in scope, contracts, the tests that call it |
| `auk hatch <file> [--hole N] [--tries 3] [--dry-run]` | fill holes with an AI model (`AUK_HATCH_CMD`, default `claude -p`); each answer must type-check and pass the function's tests, with errors (and failing tests' execution traces) fed back for up to `--tries` tries |
| `auk explain [E0xxx]` | explain an error code (with no code: list every code) |
| `auk dive [--quiet]` | the interactive REPL |
| `auk lsp` | the language server (LSP over stdio) |
| `auk mcp` | the MCP server: Auk tools for AI agents (see below) |
| `auk ir [--llvm] <file>` | print the program's MIR as C-like text (`--llvm`: its LLVM IR) |
| `auk spec` | print the compact language reference |
| `raft new\|add\|remove\|install\|list` | the package manager |

Environment: `AUK_LEAK_CHECK=1` makes `run`/`test` programs fail on leaked runtime objects,
`AUK_LINKER` names a C compiler driver (`cc`) for `auk build` to link with instead of calling
the system linker itself, and `AUK_HATCH_CMD` is the
model command `auk hatch` runs (via `sh -c`, prompt on stdin, answer on stdout; default
`claude -p`).

### Use Auk from an AI agent

`auk mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server (newline-delimited
JSON-RPC over stdio), so Claude Code or any other MCP client gets Auk tools with no setup beyond
having `auk` on the `PATH`. For Claude Code:

```sh
claude mcp add auk -- auk mcp
```

Or in a project's `.mcp.json` (or any client's MCP config):

```json
{
  "mcpServers": {
    "auk": { "command": "auk", "args": ["mcp"] }
  }
}
```

| tool | does |
|---|---|
| `auk_spec` | the language reference (agents should call it first) |
| `auk_check {path \| source}` | JSON diagnostics with codes and fix-its (`check --json`); a `path` is checked in its project |
| `auk_run {path, args?, timeout_seconds?, trace?}` | **executes** the program: exit code, stdout, stderr (30 s timeout by default); `trace: true` adds the execution trace's events (up to 2,000) |
| `auk_test {path, filter?, timeout_seconds?, trace?}` | **executes** the `test` blocks and returns the report; `trace: true` shows each failing test's last trace events |
| `auk_fmt {path \| source}` | formatted source, or rewrites the file and returns it |
| `auk_explain {code?}` | the page for an error code (no code: list every code) |
| `auk_holes {path}` | the typed holes (`??`) in a file, as JSON |

Each tool runs the `auk` binary itself as a subprocess, with no stdin and a timeout.

### Packages: `raft`

`raft` is Auk's package manager ([`docs/raft.md`](docs/raft.md)). Packages declare their effects, and raft
refuses any dependency whose effects your project doesn't allow, so `raft.toml` bounds what your whole
dependency tree can do.

```sh
./target/debug/raft new weather && cd weather
../target/debug/raft add http      # error until raft.toml allows effects = ["net"]
../target/debug/raft list          # dependency tree with versions and effects
```

The official packages live in [`packages/`](packages/) (the default registry): `json`, `csv`, `regex`, `cli`
and `http`. `examples/` is itself a raft project (it depends on `http` and `json`); run
`raft install` there before running `fetch.auk`, `router.auk` or `todo.auk`.

## How the compiler works

```
source ─▶ lexer ─▶ parser ─▶ resolve ─▶ checker ─▶ patterns/effects ─▶ lower ─▶ MIR ─▶ LLVM ─▶ JIT (run/test) or object + libauk_rt.a ─▶ executable
          tokens   AST       modules    types,     exhaustiveness,     RC and
                             and names  shapes     `uses`              control flow
```

- **lexer / parser** (`compiler/src/lexer.auk`, `parser.auk`): newline-terminated statements, string
  interpolation, recursive descent with precedence climbing.
- **resolve** (`compiler/src/resolve.auk`): the module tree of the project, its `.raft/` dependencies, and
  the core library in `compiler/prelude/*.auk`.
- **checker** (`compiler/src/check*.auk`): inference driven by the expected type,
  overloading and dot calls, shapes (monomorphized), auto-wrapping into `T?`/`T!`, units of
  measure (`units.auk`; erased before codegen).
- **patterns / effects** (`compiler/src/patterns.auk`, `effect_check.auk`): clause and `match`
  exhaustiveness and reachability; `uses` checking against each function and `raft.toml`.
- **lower / MIR / LLVM** (`compiler/src/mir/`, `codegen.auk`, `drive.auk`): each program becomes MIR, a
  structured IR with explicit reference counting, then machine code with LLVM: compiled in
  memory and run in-process for `run`/`test`, or an object file linked into an executable for
  `build`. The runtime is [`runtime/c`](runtime/c/), written in C (linked into the `auk`
  binary for the JIT, and embedded as a static library for `build`).
- **diagnostics** (`compiler/src/diag.auk`): stable codes, notes and fix-its; every code has a page in
  [`docs/errors/`](docs/errors/) (`auk explain E0400`).

The compiler is written in Auk itself (it was ported from Rust, tag `v0-rust-final`; see
[`docs/self-host-plan.md`](docs/self-host-plan.md)). [`docs/compiler.md`](docs/compiler.md) has the full architecture: source layout, runtime ABI, and
how contracts, holes, tests, `peek` and `imprint` compile.

## Editors

[`editors/vscode/`](editors/vscode/) is a VS Code extension: syntax highlighting plus the
language server (`auk lsp`) for diagnostics, quick fixes, hover, go to definition, formatting and the outline view.

## License

MIT. See [LICENSE](LICENSE).
