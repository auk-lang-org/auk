/// Declarative argument parsing for `fn main(args: [str])`. Build a `Spec`
/// with chained calls, `parse` the args, then read typed values from `Matches`.
/// `-h` and `--help` are built in and produce `Help(text)`.

// ---- spec ----

/// What the program accepts. Start with `app(name, about)` and chain builders.
pub struct Spec { name: str, about: str, opts: [Opt], pos: [Pos] }

/// One option. `meta` names its value in help text ("" for a switch).
pub struct Opt { long: str, short: char?, meta: str, help: str, kind: OptKind }

/// One positional argument.
pub struct Pos { name: str, help: str, need: Need }

/// `Flag` takes no value; `Single` takes one value at most once; `Repeated` may be given many times.
pub enum OptKind { Flag, Single, Repeated }

/// `Required` must be present; `Optional` may be absent; `Variadic` takes everything left.
pub enum Need { Required, Optional, Variadic }

/// Start a spec for program `name`, described by `about` in the help text.
pub fn app(name: str, about: str): Spec = Spec { name, about, opts: [], pos: [] }

/// Add a boolean switch: `--long` or `-s`. Giving it twice counts twice (see `count`).
pub fn switch(s: Spec, long: str, short: char?, help: str): Spec =
  s.add_opt(Opt { long, short, meta: "", help, kind: Flag })

/// Add an option that takes one value: `--long v`, `--long=v`, `-s v`, `-sv`, `-s=v`.
pub fn option(s: Spec, long: str, short: char?, meta: str, help: str): Spec =
  s.add_opt(Opt { long, short, meta, help, kind: Single })

/// Like `option`, but it may be given many times; read all values with `opts`.
pub fn repeated(s: Spec, long: str, short: char?, meta: str, help: str): Spec =
  s.add_opt(Opt { long, short, meta, help, kind: Repeated })

/// Add a required positional. Required positionals come before all others.
pub fn arg(s: Spec, name: str, help: str): Spec
  requires s.pos.all(p => p.need == Required)
{
  s.add_pos(Pos { name, help, need: Required })
}

/// Add an optional positional, filled only if enough args are given.
pub fn optional(s: Spec, name: str, help: str): Spec
  requires s.pos.all(p => p.need != Variadic)
{
  s.add_pos(Pos { name, help, need: Optional })
}

/// Collect all remaining positionals; read them with `rest`. At most one, and it comes last.
pub fn variadic(s: Spec, name: str, help: str): Spec
  requires s.pos.all(p => p.need != Variadic)
{
  s.add_pos(Pos { name, help, need: Variadic })
}

fn add_opt(s: Spec, o: Opt): Spec
  requires o.long.len() > 0 && o.long != "help" && !o.long.starts_with("-")
  requires s.opts.all(x => x.long != o.long)
  requires !short_is(o.short, 'h') && s.opts.all(x => !same_short(x.short, o.short))
{
  Spec { opts: s.opts + [o], ..s }
}

fn add_pos(s: Spec, p: Pos): Spec
  requires s.pos.all(x => x.name != p.name)
{
  Spec { pos: s.pos + [p], ..s }
}

fn short_is(c: char?, want: char): bool
fn short_is(some(c), want: char): bool = c == want
fn short_is(none, _: char): bool = false

fn same_short(a: char?, b: char?): bool
fn same_short(some(x), some(y)): bool = x == y
fn same_short(_: char?, _: char?): bool = false

// ---- errors ----

/// Why parsing stopped. `Help` is not a failure: it carries the help text to print.
pub enum CliErr {
  Help(text: str),                             // -h / --help was given
  Unknown(arg: str),                           // an option the spec doesn't declare
  MissingValue(name: str),                     // an option with no value after it
  FlagValue(name: str),                        // --switch=value
  Duplicate(name: str),                        // a Single option given twice
  Missing(name: str),                          // a required positional is absent
  Extra(arg: str),                             // a positional nothing accepts
  BadValue(name: str, value: str, want: str),  // e.g. --count=abc
}

/// A one-line message for the user (the full help text for `Help`).
pub fn message(e: CliErr): str
fn message(Help(text)): str = text
fn message(Unknown(a)): str = "error: unknown option '{a}' (try --help)"
fn message(MissingValue(n)): str = "error: option --{n} needs a value"
fn message(FlagValue(n)): str = "error: option --{n} takes no value"
fn message(Duplicate(n)): str = "error: option --{n} was given more than once"
fn message(Missing(n)): str = "error: missing required argument <{n}> (try --help)"
fn message(Extra(a)): str = "error: unexpected argument '{a}' (try --help)"
fn message(BadValue(n, v, want)): str = "error: --{n} expects {want}, got '{v}'"

/// The exit code for an error: 0 for `Help`, 2 (usage error) for everything else.
pub fn code(e: CliErr): int
fn code(Help(_)): int = 0
fn code(_: CliErr): int = 2

/// Print the message and return the exit code: `parse(...) else e => return e.report()`.
pub fn report(e: CliErr): int {
  print(e.message())
  e.code()
}

// ---- help text ----

/// The one-line usage summary, e.g. `usage: cp [options] <src> <dst> [more...]`.
pub fn usage(s: Spec): str {
  var parts = ["usage:", s.name, "[options]"]
  for p in s.pos { parts.push(shown(p.name, p.need)) }
  parts.join(" ")
}

/// The full help: usage, description, options and arguments.
pub fn help(s: Spec): str {
  var out = [s.usage()]
  if s.about != "" { out += ["", s.about] }
  out += ["", "options:"]
  for o in s.opts { out.push(row(left(o), o.help + note(o.kind))) }
  out.push(row("-h, --help", "show this help"))
  if s.pos.len() > 0 {
    out += ["", "arguments:"]
    for p in s.pos { out.push(row(shown(p.name, p.need), p.help)) }
  }
  out.join("\n")
}

fn shown(n: str, Required): str = "<{n}>"
fn shown(n: str, Optional): str = "[{n}]"
fn shown(n: str, Variadic): str = "[{n}...]"

fn note(Repeated): str = " (repeatable)"
fn note(_: OptKind): str = ""

fn left(o: Opt): str {
  let sh = match o.short { some(c) => "-{c}, ", none => "    " }
  let meta = if o.kind == Flag { "" } else { " {o.meta}" }
  "{sh}--{o.long}{meta}"
}

fn row(l: str, r: str): str = if l.len() < 24 { "  {l:<24}{r}" } else { "  {l}\n  {"":<24}{r}" }

// ---- parsing ----

/// Parsed arguments. Read them with `flag`, `count`, `opt`, `opts`, `int_opt`, `pos`, `rest`.
pub struct Matches { counts: {str: int}, values: {str: [str]}, named: {str: str}, extra: [str] }

// How one command-line word reads.
enum Tok { Word(s: str), Dashes, Long(name: str, val: str?), Shorts(cs: [char]) }

fn tok("--"): Tok = Dashes
fn tok("-"): Tok = Word("-")
fn tok("--" + body): Tok = long_tok(body)
fn tok("-" + body): Tok = Shorts(body.chars())
fn tok(a: str): Tok = Word(a)

fn long_tok(body: str): Tok {
  let i = body.find("=") else return Long(body, none)
  Long(body[0..i], body[i + 1..body.len()])
}

/// Parse `args` (without the program name, i.e. `args.skip(1)` in `main`).
/// Options and positionals may be interleaved; everything after `--` is positional.
/// A value that starts with `-` must be attached: `--n=-5` or `-n-5`.
pub fn parse(s: Spec, args: [str]): Matches!CliErr {
  var m = Matches { counts: {}, values: {}, named: {}, extra: [] }
  var free: [str] = []
  var i = 0
  while i < args.len() {
    let next = args.get(i + 1)
    let used_next = match tok(args[i]) {
      Word(w) => {
        free.push(w)
        false
      }
      Dashes => {
        free += args.skip(i + 1)
        break
      }
      Long("help", _) => fail(Help(s.help()))
      Long(name, val) => {
        let o = s.by_long(name) else fail(Unknown("--" + name))
        apply(o, val, next, &m)?
      }
      Shorts(cs) => shorts(s, cs, next, &m)?
    }
    i += if used_next { 2 } else { 1 }
  }
  bind(s.pos, free, &m)?
  m
}

fn by_long(s: Spec, name: str): Opt? = s.opts.find(o => o.long == name)
fn by_short(s: Spec, c: char): Opt? = s.opts.find(o => short_is(o.short, c))

// `-abc`: each char is a switch until one takes a value; that one uses the
// rest of the word (`-ofile`, `-o=file`) or else the next arg. Returns true if
// the next arg was used.
fn shorts(s: Spec, cs: [char], next: str?, m: var Matches): bool!CliErr {
  for k, c in cs {
    if c == 'h' { fail(Help(s.help())) }
    let o = s.by_short(c) else fail(Unknown("-" + str(c)))
    if o.kind != Flag {
      let tail = match cs.skip(k + 1) {
        ['=', ..v] => v
        v => v
      }
      if tail.len() > 0 { return apply(o, str(tail), none, &m) }
      return apply(o, none, next, &m)
    }
    let _ = apply(o, none, none, &m)?
  }
  false
}

// Record one occurrence of `o` with an attached value `val`, or else `next`.
// Returns true if `next` was used.
fn apply(o: Opt, val: str?, next: str?, m: var Matches): bool!CliErr = match (o.kind, val, next) {
  (Flag, some(_), _) => fail(FlagValue(o.long))
  (Flag, none, _) => {
    m.counts[o.long] = m.count(o.long) + 1
    false
  }
  (_, some(v), _) => {
    m.store(o, v)?
    false
  }
  (_, none, some(v)) when value_like(v) => {
    m.store(o, v)?
    true
  }
  _ => fail(MissingValue(o.long))
}

fn value_like(s: str): bool = s == "-" || !s.starts_with("-")

fn store(m: var Matches, o: Opt, v: str): ()!CliErr {
  if !m.values.contains(o.long) {
    m.values[o.long] = [v]
    return
  }
  if o.kind == Single && m.values[o.long].len() > 0 { fail(Duplicate(o.long)) }
  m.values[o.long].push(v)  // in place: a much-repeated option stays linear
}

// Assign free words to positionals in order.
fn bind(ps: [Pos], xs: [str], m: var Matches): ()!CliErr
fn bind([], [], _: var Matches): ()!CliErr = ()
fn bind([], [x, .._]: [str], _: var Matches): ()!CliErr = fail(Extra(x))
fn bind([p, ..ps]: [Pos], xs: [str], m: var Matches): ()!CliErr = match (p.need, xs) {
  (Variadic, _) => m.extra = xs
  (Required, []) => fail(Missing(p.name))
  (Optional, []) => bind(ps, [], &m)
  (_, [x, ..t]) => {
    m.named[p.name] = x
    bind(ps, t, &m)
  }
}

// ---- reading results ----

/// True if switch `name` was given.
pub fn flag(m: Matches, name: str): bool = m.count(name) > 0

/// How many times switch `name` was given (`-vvv` is 3).
pub fn count(m: Matches, name: str): int = m.counts.get(name) else 0

/// The value of option `name` (the last one, for a repeated option), or none.
pub fn opt(m: Matches, name: str): str? {
  let [.., v] = m.opts(name) else return none
  v
}

/// Every value given for option `name`, in order.
pub fn opts(m: Matches, name: str): [str] = m.values.get(name) else []

/// Option `name` as an int: `fallback` if absent, `BadValue` if not a number.
pub fn int_opt(m: Matches, name: str, fallback: int): int!CliErr {
  let v = m.opt(name) else return fallback
  int.parse(v) else fail(BadValue(name, v, "an integer"))
}

/// The value of positional `name`, or none if it is optional and absent.
pub fn pos(m: Matches, name: str): str? = m.named.get(name)

/// The words collected by the variadic positional (empty if none was declared).
pub fn rest(m: Matches): [str] = m.extra

// ---- tests ----

fn demo(): Spec = app("cp", "copy files")
  .switch("verbose", 'v', "say more")
  .switch("force", 'f', "overwrite")
  .switch("dry-run", none, "do nothing")
  .option("out", 'o', "DIR", "target directory")
  .option("mode", none, "N", "file mode")
  .repeated("exclude", 'x', "GLOB", "skip matching files")
  .arg("src", "file to copy")
  .optional("dst", "where to copy it")
  .variadic("more", "more files")

test "switches, short and long" {
  let m = demo().parse(["-v", "--force", "a"])?
  assert m.flag("verbose") && m.flag("force")
  assert !m.flag("dry-run")
  assert m.count("verbose") == 1
  assert (demo().parse(["--dry-run", "a"])?).flag("dry-run")
}

test "combined short switches count" {
  let m = demo().parse(["-vfv", "a"])?
  assert m.count("verbose") == 2
  assert m.flag("force")
}

test "option value forms" {
  assert (demo().parse(["-o", "x", "a"])?).opt("out") is some("x")
  assert (demo().parse(["-ox", "a"])?).opt("out") is some("x")
  assert (demo().parse(["-o=x", "a"])?).opt("out") is some("x")
  assert (demo().parse(["--out", "x", "a"])?).opt("out") is some("x")
  assert (demo().parse(["--out=x", "a"])?).opt("out") is some("x")
  assert (demo().parse(["--out=", "a"])?).opt("out") is some("")
  assert (demo().parse(["-vo", "x", "a"])?).opt("out") is some("x")
  assert (demo().parse(["--out=-", "a"])?).opt("out") is some("-")
  assert (demo().parse(["a"])?).opt("out") is none
}

test "repeated options" {
  let m = demo().parse(["-x", "*.o", "a", "--exclude=*.tmp", "-x.git"])?
  assert m.opts("exclude") == ["*.o", "*.tmp", ".git"]
  assert m.opt("exclude") is some(".git")
  assert m.opts("out") == []
}

test "int options" {
  assert (demo().parse(["--mode", "644", "a"])?).int_opt("mode", 0)? == 644
  assert (demo().parse(["--mode=-1", "a"])?).int_opt("mode", 0)? == -1
  assert (demo().parse(["a"])?).int_opt("mode", 7)? == 7
  let m = demo().parse(["--mode", "rw", "a"])?
  assert m.int_opt("mode", 0) is err(BadValue("mode", "rw", "an integer"))
}

test "positionals" {
  let m = demo().parse(["a"])?
  assert m.pos("src") is some("a")
  assert m.pos("dst") is none
  assert m.rest() == []
  let m2 = demo().parse(["a", "-v", "b", "c", "d"])?
  assert m2.pos("src") is some("a")
  assert m2.pos("dst") is some("b")
  assert m2.rest() == ["c", "d"]
  assert m2.flag("verbose")
  assert (demo().parse(["-", "b"])?).pos("src") is some("-")
}

test "double dash ends options" {
  let m = demo().parse(["-v", "--", "-f", "--out=x", "--"])?
  assert m.pos("src") is some("-f")
  assert m.pos("dst") is some("--out=x")
  assert m.rest() == ["--"]
  assert !m.flag("force")
}

test "help is requested, not failed" {
  assert demo().parse(["a", "--help"]) is err(Help(_))
  assert demo().parse(["-vh"]) is err(Help(_))
  let e = Help("text")
  assert e.code() == 0
  assert e.message() == "text"
}

test "errors" {
  assert demo().parse(["--nope", "a"]) is err(Unknown("--nope"))
  assert demo().parse(["-vq", "a"]) is err(Unknown("-q"))
  assert demo().parse(["a", "-o"]) is err(MissingValue("out"))
  assert demo().parse(["--out", "-v", "a"]) is err(MissingValue("out"))
  assert demo().parse(["--verbose=yes", "a"]) is err(FlagValue("verbose"))
  assert demo().parse(["-o", "x", "--out=y", "a"]) is err(Duplicate("out"))
  assert demo().parse([]) is err(Missing("src"))
  assert demo().parse(["-v"]) is err(Missing("src"))
  let two = app("t", "").arg("a", "")
  assert two.parse(["x", "y"]) is err(Extra("y"))
  assert two.parse(["--", "x", "-y"]) is err(Extra("-y"))
  assert Unknown("--nope").message() == "error: unknown option '--nope' (try --help)"
  assert Missing("src").code() == 2
}

test "usage and help text" {
  assert demo().usage() == "usage: cp [options] <src> [dst] [more...]"
  let h = demo().help()
  assert h.starts_with("usage: cp [options] <src> [dst] [more...]\n\ncopy files\n\noptions:\n")
  assert h.contains("  -v, --verbose           say more\n")
  assert h.contains("      --dry-run           do nothing\n")
  assert h.contains("  -o, --out DIR           target directory\n")
  assert h.contains("  -x, --exclude GLOB      skip matching files (repeatable)\n")
  assert h.contains("  -h, --help              show this help\n")
  assert h.ends_with("arguments:\n  <src>                   file to copy\n  [dst]                   where to copy it\n  [more...]               more files")
  assert app("x", "").help() ==
    "usage: x [options]\n\noptions:\n  -h, --help              show this help"
  let wide = app("x", "").option("a-very-long-option", none, "VALUE", "wide")
  assert wide.help().contains("\n      --a-very-long-option VALUE\n                          wide\n")
}

test "subcommand dispatch on rest" {
  let spec = app("todo", "").switch("all", 'a', "").variadic("cmd", "")
  assert demo_run((spec.parse(["add", "buy", "milk"])?).rest()) == "add buy milk"
  assert demo_run((spec.parse(["-a", "ls"])?).rest()) == "ls"
  assert demo_run((spec.parse(["done", "x", "y"])?).rest()) == "?"
}

fn demo_run(["add", ..words]: [str]): str = "add " + words.join(" ")
fn demo_run(["ls"]: [str]): str = "ls"
fn demo_run(_: [str]): str = "?"
