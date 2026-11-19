# Effects

A function that touches the outside world says so in its signature. A function that doesn't
say so is **pure**: its result depends only on its arguments, and the compiler enforces that.

```auk
fn word_count(text: str): int = text.split().len()                 // pure

fn count_file(path: str): int! uses fs = word_count(fs.read(path)?)   // reads a file

fn main(args: [str]): ()! uses fs {
  print(count_file(args[1])?)
}
```

## The effects

| effect | allows | core module |
|---|---|---|
| `fs` | reading and writing files and directories | `fs` |
| `net` | sockets, TLS, listening | `net` |
| `time` | the clock and sleeping | `time` |
| `rand` | random numbers | `rand` |
| `env` | environment variables, arguments, standard input, the terminal | `env` |
| `proc` | running other programs, exiting | `proc` |
| `gui` | windows | `gui` |
| `audio_out` | playing sound | `audio_out` |
| `ffi` | calling C functions | see [Calling C](c-interop.md) |

`print` and `eprint` are always allowed, so adding a debugging line never changes a
signature.

## The rule

A function must declare every effect it uses, directly or through anything it calls. Forget
one and the compiler names the call that needs it and offers the fix:

```console
main.auk:3:9: error[E0410]: `main` uses the effects `env`, `time` but doesn't declare them
  |
3 |   print(env.get("HOME") is some(_))
  |         ^^^^^^^^^^^^^^^
  = note: call chain: `main` → `env.get` (uses env)
  = note: call chain: `main` → `time.now` (uses time)
  = fix: insert ` uses env, time` at 2:10
```

Declaring an effect you don't use is a warning (E0411), so signatures stay honest in both
directions.

Details worth knowing:

- A closure's effects count for the function it is written in. `paths.map(p => fs.read(p))`
  needs `uses fs` on the enclosing function, and `map` itself stays pure.
- Top-level `let` constants and `imprint` values are computed without effects, so their
  initializers must be pure (E0412). Read configuration in `main` and pass it down.
- Guards (`when`) and contracts must be pure.
- A shape's method declares the effects it may use: `shape Log { fn log(self, s: str) uses fs }`.
  A type whose method does more than the shape allows can't be converted to `any Log`
  (E0415).

## Effects bound a whole project

A project's `raft.toml` lists the effects its code may use:

```toml
[package]
name = "weather"
version = "0.1.0"
effects = ["net"]
```

The compiler rejects any `uses` outside that list (E0413), and `raft` refuses to install a
dependency that needs an effect the project hasn't allowed. Each package's list must be a
subset of the list of the package that depends on it, so the root manifest bounds the entire
dependency tree. `raft list` shows who uses what:

```console
$ raft list
weather 0.1.0   uses net
├── http 0.1.1   uses net
│   ├── json 0.1.0
│   └── url 0.1.0
│       └── encoding 0.1.0
└── csv 0.1.0
```

Here you know, without reading a line of their code, that `json`, `url`, `encoding` and `csv`
cannot open a file or a socket, and that no update to them ever can without the install
failing.

## Why bother

- **Reading code.** A signature with no `uses` is a promise: no I/O, no clock, no randomness.
  You can test it with plain values and call it from anywhere.
- **Reviewing code you didn't write**, including code written by an AI model or pulled in as a
  dependency. What it can reach is on the first line.
- **Testing.** Code that takes the time as an argument instead of reading the clock is
  deterministic, and the effect system nudges you to write it that way. `datetime`, for
  example, never reads the clock; you pass it `time.now()`.

A practical layout follows from this: keep the logic pure and push effects to a thin outer
layer, usually `main` and a few functions around it.

Next: [Units of measure](units.md).
