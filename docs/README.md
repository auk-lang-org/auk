# Auk documentation

Auk is a statically typed language that compiles to native code. It is designed so that code,
especially code written by AI models, takes few tokens and is checked hard: functions written
as exhaustive clauses, errors and optionals in the types, declared effects, structural
generics, units of measure, contracts, and tests in the language.

```auk
enum Shape { Circle(r: float), Rect(w: float, h: float) }

fn area(Circle(r)): float = 3.14159 * r * r      // clauses: the compiler rejects gaps
fn area(Rect(w, h)): float = w * h

fn main() {
  for s in [Circle(1.0), Rect(2.0, 3.0)] {
    print("{s} has area {area(s):.2}")
  }
}

test "area" { assert area(Rect(2.0, 3.0)) == 6.0 }
```

## Start here

| | |
|---|---|
| [Getting started](getting-started.md) | install, run, test and build a program; make a project with a dependency |
| [A tour of Auk](tour.md) | the language in one sitting, through one small program |

## The language

Read in order, or jump to what you need.

| | |
|---|---|
| [Basics](language/basics.md) | bindings, built-in types, strings, lists and maps, control flow, operators |
| [Functions, clauses and patterns](language/functions.md) | dot calls, closures, `var` parameters, clause groups, every pattern |
| [Structs, enums and shapes](language/types.md) | data types, structural generics, `any`, operators on your types, `Data` |
| [Errors and optionals](language/errors.md) | `T?`, `T!`, `T!E`, `?`, `else`, `fail`, panics and `catch` |
| [Effects](language/effects.md) | `uses`, purity, and how effects bound a whole dependency tree |
| [Units of measure](language/units.md) | `float<m/s>`: checked at compile time, free at run time |
| [Concurrency](language/concurrency.md) | tasks, `await`, channels, cancellation, supervisors |
| [Tests, contracts and holes](language/testing.md) | `test`, `requires`/`ensures`, `??`, `peek`, `imprint` |
| [Modules and packages](language/modules.md) | files as modules, no imports, visibility, `main` |
| [Calling C](language/c-interop.md) | `extern fn` with C prototypes, pointers, embedding files |

## Tools

| | |
|---|---|
| [The `auk` command line](tools/cli.md) | `run`, `test`, `check`, `build`, `fmt`, `explain`, the REPL |
| [raft, the package manager](tools/raft.md) | projects, `raft.toml`, versions, the lock file, effects per package |
| [Testing and debugging](tools/debugging.md) | execution traces, `auk debug`, native debug info |
| [Live reload](tools/live-reload.md) | `auk run --live`: change a running program without restarting it |
| [Auk with AI coding agents](tools/ai.md) | JSON diagnostics, the MCP server, holes and `auk hatch` |
| [Editors](tools/editors.md) | the VS Code extension, the language server, the debug adapter |

## Reference

| | |
|---|---|
| [Core library](reference/core.md) | everything available without a package |
| [Package catalog](reference/packages.md) | the official packages and their effects |
| `auk spec` | the whole language, compactly; the same text as `docs/spec.md` |
| `auk explain` | every error code, each with a page |

## Working on Auk itself

The compiler and runtime are written in Auk. Their documentation is in `docs/`:

| | |
|---|---|
| [`docs/compiler.md`](compiler.md) | architecture: the pipeline, source layout, runtime ABI, back end, how to build and test |
| [`docs/lowlevel.md`](lowlevel.md) | `raw`, the low-level dialect the runtime is written in |
| [`docs/raft.md`](raft.md) | the package manager's design notes |

## Platforms

macOS (Apple silicon) and Linux (arm64 and x86-64). Windows is planned. GUI windows are
macOS-only so far.
