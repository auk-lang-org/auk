# Duck

A statically typed language that compiles to native code with Cranelift, designed so that code
(especially AI-written code) takes few tokens and is checked hard: clause functions with
exhaustiveness checking, errors and optionals in the types (`T!`, `T?`), declared effects
(`uses fs, net`), structural generics ("shapes"), units of measure (`9.81<m/s^2>`, checked at
compile time and erased at run time), contracts, and tests in the language.

```duck
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

The language reference is [`docs/spec.md`](docs/spec.md) (also printed by `duck spec`). Runnable
programs live in [`examples/`](examples/): start with `hello.duck`, `fib.duck` and `tour.duck`.

## Usage

Requires Rust. `duck run`/`test` compile in memory (Cranelift JIT); `duck build` also needs a
system linker (`cc`).

```sh
cargo build
./target/debug/duck run examples/tour.duck              # compile and run
./target/debug/duck build examples/fib.duck -o fib      # native executable (release; refuses `??` holes)
./target/debug/duck check examples/calc.duck --json     # type-check only; JSON diagnostics for agents
./target/debug/duck test examples/bank.duck             # run the `test` blocks (a file or a project dir)
cargo test                                              # the compiler's whole test suite
```

| command | does |
|---|---|
| `duck run <file> [args...]` | compile and run the program |
| `duck run --live <file> [args...]` | run, and swap in new code on every save: state, tasks and sockets survive; a type error keeps the old code; a changed struct/enum layout stops just the tasks that use it (their `sup` supervisors restart them on the new code), or restarts the program when `main` uses it |
| `duck run --trace=json\|<file> <file> [args...]` | run with an execution trace: every call (args shown), return value or error, `peek` and panic as JSON Lines (`json` = stderr) |
| `duck build <file> [-o out]` | compile to a native executable (release build; refuses `??` holes) |
| `duck check <file> [--json]` | type-check only; `--json` for machine-readable diagnostics with fix-its |
| `duck test [file\|dir] [filter]` | build and run the `test` blocks of a file, a project, or each file of a flat dir |
| `duck test --trace=json\|<dir> ...` | each FAIL line is followed by the last events of that test's trace (`json`), or every test's trace goes to `<dir>/<test>.jsonl`; `--trace-limit N` (default 10,000 events), `--trace-core` (also trace the core library) |
| `duck fmt [--check] <path>...` | format `.duck` files in place (`-` = stdin to stdout) |
| `duck holes <file> [--json]` | brief every `??` hole: expected type, variables in scope, contracts, the tests that call it |
| `duck hatch <file> [--hole N] [--tries 3] [--dry-run]` | fill holes with an AI model (`DUCK_HATCH_CMD`, default `claude -p`); each answer must type-check and pass the function's tests, with errors (and failing tests' execution traces) fed back for up to `--tries` tries |
| `duck explain [E0xxx]` | explain an error code (with no code: list every code) |
| `duck pond [--quiet]` | the interactive REPL |
| `duck lsp` | the language server (LSP over stdio) |
| `duck mcp` | the MCP server: Duck tools for AI agents (see below) |
| `duck ir [--clif] <file>` | print the program's MIR as C-like text (`--clif`: its Cranelift IR) |
| `duck spec` | print the compact language reference |
| `quack new\|add\|remove\|install\|list` | the package manager |

Environment: `DUCK_LEAK_CHECK=1` makes `run`/`test` programs fail on leaked runtime objects,
`DUCK_LINKER` picks the linker `duck build` uses (default `cc`), and `DUCK_HATCH_CMD` is the
model command `duck hatch` runs (via `sh -c`, prompt on stdin, answer on stdout; default
`claude -p`).

### Use Duck from an AI agent

`duck mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server (newline-delimited
JSON-RPC over stdio), so Claude Code or any other MCP client gets Duck tools with no setup beyond
having `duck` on the `PATH`. For Claude Code:

```sh
claude mcp add duck -- duck mcp
```

Or in a project's `.mcp.json` (or any client's MCP config):

```json
{
  "mcpServers": {
    "duck": { "command": "duck", "args": ["mcp"] }
  }
}
```

| tool | does |
|---|---|
| `duck_spec` | the language reference (agents should call it first) |
| `duck_check {path \| source}` | JSON diagnostics with codes and fix-its (`check --json`); a `path` is checked in its project |
| `duck_run {path, args?, timeout_seconds?, trace?}` | **executes** the program: exit code, stdout, stderr (30 s timeout by default); `trace: true` adds the execution trace's events (up to 2,000) |
| `duck_test {path, filter?, timeout_seconds?, trace?}` | **executes** the `test` blocks and returns the report; `trace: true` shows each failing test's last trace events |
| `duck_fmt {path \| source}` | formatted source, or rewrites the file and returns it |
| `duck_explain {code?}` | the page for an error code (no code: list every code) |
| `duck_holes {path}` | the typed holes (`??`) in a file, as JSON |

Each tool runs the `duck` binary itself as a subprocess, with no stdin and a timeout.

### Packages: `quack`

`quack` is Duck's package manager ([`docs/quack.md`](docs/quack.md)). Packages declare their effects, and quack
refuses any dependency whose effects your project doesn't allow, so `quack.toml` bounds what your whole
dependency tree can do.

```sh
./target/debug/quack new weather && cd weather
../target/debug/quack add http      # error until quack.toml allows effects = ["net"]
../target/debug/quack list          # dependency tree with versions and effects
```

The official packages live in [`packages/`](packages/) (the default registry): `json`, `csv`, `regex`, `cli`
and `http`. `examples/` is itself a quack project (it depends on `http` and `json`); run
`quack install` there before running `fetch.duck`, `router.duck` or `todo.duck`.

## How the compiler works

```
source ─▶ lexer ─▶ parser ─▶ resolve ─▶ checker ─▶ patterns/effects ─▶ lower ─▶ MIR ─▶ Cranelift ─▶ JIT (run/test) or object + libduck_rt.a ─▶ executable
          tokens   AST       modules    types,     exhaustiveness,     RC and
                             and names  shapes     `uses`              control flow
```

- **lexer / parser** (`src/lexer.rs`, `src/parser.rs`): newline-terminated statements, string
  interpolation, recursive descent with precedence climbing.
- **resolve** (`src/resolve.rs`): the module tree of the project, its `.quack/` dependencies, and
  the core library in `src/prelude/*.duck`.
- **checker** (`src/check.rs`, `src/check/`): inference driven by the expected type,
  overloading and dot calls, shapes (monomorphized), auto-wrapping into `T?`/`T!`, units of
  measure (`src/units.rs`; erased before codegen).
- **patterns / effects** (`src/patterns.rs`, `src/effects.rs`): clause and `match`
  exhaustiveness and reachability; `uses` checking against each function and `quack.toml`.
- **lower / MIR / Cranelift** (`src/mir/`, `src/build.rs`): each program becomes MIR, a
  structured IR with explicit reference counting, then machine code with Cranelift: compiled in
  memory and run in-process for `run`/`test`, or an object file linked into an executable for
  `build`. The runtime is [`runtime/`](runtime/), the Rust crate `duck_rt` (linked into the
  `duck` binary for the JIT, and embedded as a static library for `build`).
- **diagnostics** (`src/diag.rs`): stable codes, notes and fix-its; every code has a page in
  [`docs/errors/`](docs/errors/) (`duck explain E0400`).

[`docs/compiler.md`](docs/compiler.md) has the full architecture: source layout, runtime ABI, and
how contracts, holes, tests, `peek` and `imprint` compile.

## Editors

[`editors/vscode/`](editors/vscode/) is a VS Code extension: syntax highlighting plus the
language server (`duck lsp`) for diagnostics, quick fixes, hover, go to definition, formatting and the outline view.
