# Getting started

This page takes you from a fresh clone to a tested, built program and a project with a
dependency. It takes about ten minutes.

## Install

Auk builds from source. You need:

| | macOS | Linux |
|---|---|---|
| LLVM 23 | `brew install llvm@23` | `llvm-23-dev` and `lld-23` from [apt.llvm.org](https://apt.llvm.org) |
| A linker and the C library's stubs | the Command Line Tools: `xcode-select --install` | `ld.lld` (or binutils' `ld`) and `libc6-dev` |

You do not need a C compiler, Rust, or an existing `auk`. The compiler and the runtime are
written in Auk, and a fresh clone bootstraps from the compiler checked in as LLVM bitcode in
`seed/`.

```sh
git clone <this repository> auk && cd auk
./build.sh --install                 # builds the runtime, raft and auk; copies them to ~/.auk/bin
export PATH="$HOME/.auk/bin:$PATH"   # add this line to your shell profile
auk --version
```

The build takes under a minute. `./build.sh --check --test --install` also proves the compiler
rebuilds itself bit for bit and runs the test suites; use it before you send a change to the
compiler. Windows is not supported yet.

## Hello

Put this in `hello.auk`:

```auk
fn main() {
  print("hello, world")
}
```

```console
$ auk run hello.auk
hello, world
```

`auk run` compiles the program in memory and runs it. There is no separate build step while
you work, and a small program is running in about a tenth of a second.

## A program with something to check

```auk
enum Shape { Circle(r: float), Rect(w: float, h: float) }

fn area(Circle(r)): float = 3.14159 * r * r
fn area(Rect(w, h)): float = w * h

fn parse_side(s: str): float! {
  let x = float.parse(s) else fail("not a number: {s}")
  if x <= 0.0 { fail("sides must be positive") }
  x
}

fn main(args: [str]): int! {
  let sides = args.skip(1).map(a => parse_side(a))?
  let shapes = sides.map(s => Rect(s, s)) + [Circle(1.0)]
  for s in shapes {
    print("{s} has area {area(s):.2}")
  }
  0
}

test "area" { assert area(Rect(2.0, 3.0)) == 6.0 }
```

Save it as `shapes.auk` and try the four commands you will use most:

```console
$ auk run shapes.auk 2 3
Rect(2.0, 2.0) has area 4.00
Rect(3.0, 3.0) has area 9.00
Circle(1.0) has area 3.14

$ auk run shapes.auk 2 x
error: not a number: x

$ auk test shapes.auk
ok area
1 passed, 0 failed

$ auk check shapes.auk          # type-check only: no output means no errors

$ auk build shapes.auk -o shapes && ./shapes 4
Rect(4.0, 4.0) has area 16.00
Circle(1.0) has area 3.14
```

What the program shows:

- **Clauses.** `area` is written as one clause per case. Delete the `Rect` clause and
  `auk check` reports `area(Rect(_, _))` is not handled, with the clause to add as a fix. A
  program never runs with a gap in it.
- **Errors in the types.** `float!` means "a float, or an error". `?` passes an error up,
  `else` handles one, and `fail` raises one. An error that reaches the end of `main` is printed
  and the program exits with status 1.
- **Tests in the language.** `test` blocks live next to the code and are left out of built
  programs.
- **No ceremony.** No imports, no semicolons, no type arguments at call sites.

## When the compiler says no

Diagnostics carry a stable code, the exact span and, where one exists, a fix:

```console
$ auk check oops.auk
oops.auk:2:16: error[E0200]: expected `int`, found `str`
  |
2 |   let x: int = "hi"
  |                ^^^^
  = help: run `auk explain E0200` for details
```

`auk explain E0200` prints a page about the error with examples of the mistake and the fix.
`auk explain` alone lists every code.

## A project with a dependency

A single file is enough for a script. Anything bigger is a project, managed by `raft`:

```console
$ raft new weather
created weather/ (app)
$ cd weather && ls -a
.gitignore  raft.toml  src
```

`src/main.auk` is the entry point, and `raft.toml` is the manifest:

```toml
[package]
name = "weather"
version = "0.1.0"
effects = []

[deps]
```

`effects` is the list of things this project, and everything it depends on, may do to the
outside world. It starts empty, so adding a package that needs the network fails:

```console
$ raft add http
error: http 0.1.1 needs effect `net`, but weather's raft.toml only allows []
  help: add "net" to [package] effects in raft.toml
```

Change the line to `effects = ["net"]`, and it installs:

```console
$ raft add http
  + http 0.1.1       uses net
  + json 0.1.0       (via http)
  + url 0.1.0        (via http)
  + encoding 0.1.0   (via url)
```

Now `src/main.auk` can use it. A dependency is reached by its name; there is nothing to import:

```auk
fn main(): int! uses net {
  let r = await http.get("https://example.com/")?
  print("{r.status}: {r.body.len()} chars")
  0
}
```

```console
$ auk run src/main.auk
200: 577 chars
```

`main` says `uses net` because it reaches the network. Leave that out and the compiler tells
you which call needs it. [Effects](language/effects.md) explains the rule, and
[raft](tools/raft.md) covers the package manager.

## Where to go next

- [A tour of Auk](tour.md): the whole language in one sitting.
- [The language guide](README.md#the-language): one page per topic, in reading order.
- [The command line](tools/cli.md): every `auk` command.
- `examples/` in the repository: runnable programs, from `hello.auk` to an HTTP router.
- `auk dive` opens a REPL if you want to try expressions as you read.
