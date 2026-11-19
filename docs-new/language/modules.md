# Modules, packages and `main`

## A file is a module

Every `.auk` file is a module, named after the file. A single file is a complete program, and
that is all a script needs. A larger program is a **project**: a folder with a `raft.toml` and
a `src/` directory.

```
shop/
  raft.toml             the manifest
  raft.lock             exact dependency versions (generated; commit it)
  src/main.auk          the entry point of an application
  src/pricing.auk       module `pricing`
  src/geo/shapes.auk    module `geo.shapes`
  .raft/                installed dependencies (generated; don't commit)
```

`raft new shop` creates this layout (`raft new shop --lib` for a library, whose root module is
`src/lib.auk`).

## No imports

You refer to anything in another module by its path. There are no import lines to write or to
keep in order:

```auk
// src/geo/shapes.auk
pub struct Rect { w: float, h: float }
pub fn area(r: Rect): float = r.w * r.h
fn helper(): int = 1                      // private: no `pub`
```

```auk
// src/pricing.auk
pub let TAX = 0.2
pub fn with_tax(x: float): float = x * (1.0 + TAX)
```

```auk
// src/main.auk
fn main() {
  let r = geo.shapes.Rect { w: 2.0, h: 3.0 }
  print(geo.shapes.area(r))          // 6.0
  print(r.area())                    // 6.0: a dot call finds `area` by r's type
  print(pricing.with_tax(100.0))     // 120.0
}
```

The first segment of a path is one of:

1. a top-level module of your own project (`pricing`, `geo`),
2. a dependency (`json`, `http`),
3. a core module (`fs`, `net`, `time`, ...).

Dot calls are what keep paths rare in practice: `r.area()` finds the function through the type
of `r`, wherever it was defined.

## Visibility

Everything is private to its module unless marked `pub`: functions, structs, enums, shapes and
top-level `let`s. Using a private item from elsewhere is E0120, and the message tells you what
to mark. A `pub struct`'s fields are public, unless a field's type is itself private.

## Names that collide

- A module of yours named like a dependency is an error (E0101).
- A local variable named like one of your modules or dependencies is an error where it is used
  as a path (E0116). Rename the variable.
- A local named like a core module shadows it. `core.env` still reaches the module.

## Packages

A package is a project that others depend on. Its root module is `src/lib.auk`, whose `pub`
items are reached as `<package>.<item>`; other files are submodules:

| in package `http` | is reached as |
|---|---|
| `pub fn get` in `src/lib.auk` | `http.get` |
| `pub fn serve` in `src/server.auk` | `http.server.serve` |

Inside a package, its own name is its root, so code in `http` writes `http.Resp`.

Dependencies are declared once, in `raft.toml`, and added with `raft add`:

```console
$ raft add json
  + json 0.1.0
```

After that, `json.parse(text)` works everywhere in the project. [raft](../tools/raft.md)
covers versions, the lock file and local path dependencies; the
[package catalog](../reference/packages.md) lists what exists.

## `main`

A program starts at `fn main`. Its parameters and return type are optional:

```auk
fn main() { ... }                          // nothing in, nothing out
fn main(args: [str]) { ... }               // args[0] is the program's name
fn main(): ()! { ... }                     // may fail
fn main(args: [str]): int! uses fs { ... } // arguments, an exit status, errors and effects
```

- An `int` result is the exit status.
- An error that reaches the end of `main` prints `error: <message>` to stderr and exits with
  status 1.
- A panic exits with status 101.
- `main` declares the effects the program uses, like any other function, so the first line of
  a program tells you what it can touch.

```auk
fn main(args: [str]): int! {
  let name = args.get(1) else "world"
  print("hello, {name}")
  0
}
```

For real command-line parsing (flags, options, generated help), use the `cli` package.

Next: [Calling C](c-interop.md).
