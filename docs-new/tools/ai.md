# Auk with AI coding agents

Auk was designed so that code written by a model takes few tokens and is checked hard. The
language does most of that work (exhaustive clauses, errors and effects in the types,
contracts, no imports). The toolchain adds a machine-readable interface to everything.

## What an agent should use

| need | command | notes |
|---|---|---|
| Learn the language | `auk spec` | the whole language in about 180 dense lines; read it first |
| Check a change | `auk check <file> --json` | diagnostics with codes, exact spans and fix-it edits |
| Understand an error | `auk explain E0xxx` | a wrong example, the fix, common causes |
| Run tests | `auk test <path>` | exit status 1 on failure |
| See why a test failed | `auk test --trace=json <path>` | each failure with the calls, arguments and results that led to it |
| See values at a crash | `auk debug --json <file>` | locals and stack at every panic and breakpoint, no editing |
| Find unwritten code | `auk holes <file> --json` | each `??` with its expected type, scope, contracts and tests |
| Normalize style | `auk fmt <path>` | one style, no options |

Every one of these runs without a terminal, exits with a meaningful status, and prints either
plain text or JSON.

Fix-its matter more than they look. Most diagnostics carry the exact edit that repairs them
(`fixes: [{line, col, end_line, end_col, text}]`): a missing `?`, a missing `&`, an undeclared
effect, a missing clause. An agent can apply them mechanically instead of re-deriving the fix.

## The MCP server

`auk mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio.
Any MCP client gets Auk tools with no setup beyond having `auk` on the `PATH`.

For Claude Code:

```console
$ claude mcp add auk -- auk mcp
```

For any client, in its MCP configuration (for example a project's `.mcp.json`):

```json
{
  "mcpServers": {
    "auk": { "command": "auk", "args": ["mcp"] }
  }
}
```

| tool | does |
|---|---|
| `auk_spec` | returns the language reference; agents should call it first |
| `auk_check {path \| source}` | JSON diagnostics with codes and fix-its; a `path` is checked within its project |
| `auk_run {path, args?, timeout_seconds?, trace?}` | **runs** the program: exit code, stdout, stderr. `trace: true` adds the execution trace |
| `auk_test {path, filter?, timeout_seconds?, trace?}` | **runs** the tests and returns the report; `trace: true` shows each failing test's last events |
| `auk_debug {...}` | runs `auk debug --json`: locals and stack at each breakpoint and panic |
| `auk_fmt {path \| source}` | formatted source, or rewrites the file |
| `auk_explain {code?}` | the page for an error code, or the list of codes |
| `auk_holes {path}` | the typed holes in a file, as JSON |

`auk_run`, `auk_test` and `auk_debug` execute code on your machine, with a timeout (30 s by
default) and no stdin. Grant them the way you would grant a shell.

## A workflow that works: specify, then fill

Because holes type-check, a program can be specified completely before any body exists:

```auk
/// The integer square root: the largest r with r * r <= n.
fn isqrt(n: int): int
  requires n >= 0
  ensures result * result <= n
  ensures (result + 1) * (result + 1) > n
{ ?? }

test "isqrt" {
  assert isqrt(0) == 0
  assert isqrt(17) == 4
  assert isqrt(1_000_000) == 1000
}
```

1. A person (or a planning model) writes types, signatures, contracts and tests, with `??`
   for the bodies. `auk check` confirms the design hangs together.
2. `auk holes --json` turns each hole into a self-contained brief.
3. Whoever fills a hole is done when `auk check` is clean and `auk test` passes. The
   contracts are checked on every test run, so they catch answers the tests alone would miss.
4. `auk build` refuses to ship while any hole remains.

### Filling holes: `auk hatch`

`auk hatch` automates steps 2 and 3:

```console
$ auk hatch isqrt.auk
$ auk hatch isqrt.auk --hole 2 --tries 5
$ auk hatch isqrt.auk --dry-run        # ask the model, print the diff, leave the file alone
```

For each hole it sends the brief to a model, and accepts the answer only if the program then
type-checks and the tests that call the function pass. When an answer fails, the compiler
errors, or the failing tests with their execution traces, go back to the model, for up to
`--tries` attempts (default 3). The model is whatever command `AUK_HATCH_CMD` names (default
`claude -p`); it is run through `sh -c` with the prompt on stdin and the answer on stdout.

## Why the language suits generated code

- **Fewer tokens.** No imports, no semicolons, no type arguments at call sites, inference
  inside functions, clauses instead of nested conditionals.
- **Mistakes become compile errors.** A missed case, an ignored error, an unhandled `none`, a
  unit mix-up and an undeclared side effect are all rejected before the program runs.
- **Effects make review cheap.** A reviewer reads `uses` clauses and `raft.toml`, not every
  line, to know what generated code can touch.
- **One way to do things.** One formatter style, one error mechanism, one package manager,
  stable error codes.
