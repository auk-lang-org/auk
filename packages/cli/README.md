# cli

Declarative argument parsing for `fn main(args: [str])`: switches, options with values, repeated options, positionals, `--`, combined short flags, and generated help text.

**Effects:** none (`effects = []`). `report` uses `print`, which is always allowed.

## Usage
```
fn main(args: [str]): int! {
  let m = cli.app("todo", "a tiny todo list")
    .switch("all", 'a', "include finished items")
    .variadic("cmd", "add <text> | ls")
    .parse(args.skip(1)) else e => return e.report()
  run(m.rest(), m)?
  0
}
fn run(["add", ..words]: [str], _: cli.Matches): ()! = print("added: {words.join(" ")}")
fn run(["ls"]: [str], m: cli.Matches): ()! = print("all: {m.flag("all")}")
fn run(_: [str], _: cli.Matches): ()! = fail("usage: todo add <text> | ls")
```
`todo --help` prints the generated help and exits 0; `todo --bogus` prints `error: unknown option '--bogus' (try --help)` and exits 2.

## Command-line syntax accepted
- switches: `-v`, `--verbose`, combined `-vf`, counted `-vvv`
- options: `-o out`, `-oout`, `-o=out`, `--out out`, `--out=out`, and in a group `-vo out`
- a value starting with `-` must be attached (`--n=-5`, `-n-5`); `-` alone is a normal word
- options and positionals may be interleaved; everything after `--` is positional
- `-h` / `--help` are built in

## API
Building a spec (each returns a new `Spec`; duplicate names and misordered positionals fail `requires` contracts):
- `app(name, about): Spec`
- `switch(s, long, short: char?, help)`: a boolean flag
- `option(s, long, short: char?, meta, help)`: takes one value, at most once
- `repeated(s, long, short: char?, meta, help)`: takes a value, may repeat
- `arg(s, name, help)`, `optional(s, name, help)`, `variadic(s, name, help)`: positionals, in that order
- `usage(s): str`, `help(s): str`

Parsing and reading:
- `parse(s, args: [str]): Matches!CliErr`: pass `args.skip(1)`
- `flag(m, name): bool`, `count(m, name): int`
- `opt(m, name): str?` (last value), `opts(m, name): [str]` (all values)
- `int_opt(m, name, fallback: int): int!CliErr`: `fallback` if absent, `BadValue` if not an int
- `pos(m, name): str?`, `rest(m): [str]` (the variadic positional's words)

Errors:
- `enum CliErr { Help(text), Unknown(arg), MissingValue(name), FlagValue(name), Duplicate(name), Missing(name), Extra(arg), BadValue(name, value, want) }`
- `message(e): str`, `code(e): int` (0 for `Help`, else 2), `report(e): int` (prints the message, returns the code)
