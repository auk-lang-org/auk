# Errors and optionals

Auk has no exceptions and no `null`. A function that can fail, or that might have nothing to
return, says so in its return type, and the compiler makes every caller deal with it.

| type | means | built with |
|---|---|---|
| `T?` | a `T`, or nothing | a plain value, `some(v)`, `none` |
| `T!` | a `T`, or an error with a message | a plain value, `fail("message")` |
| `T!E` | a `T`, or an error that is a value of the enum `E` | a plain value, `fail(Variant)` |

A plain value converts to `T?` or `T!` wherever one is expected, so the success path needs no
wrapping.

## Optionals: `T?`

```auk
struct User { id: int, name: str }

fn find(users: [User], id: int): User? = users.find(u => u.id == id)

fn main() {
  let users = [User { id: 1, name: "ann" }, User { id: 2, name: "bo" }]

  print(find(users, 2))                           // some(User { id: 2, name: "bo" })
  print(find(users, 9))                           // none

  let name = find(users, 9)?.name else "nobody"   // ?. reaches in; else supplies the fallback
  print(name)                                     // nobody

  match find(users, 1) {
    some(u) => print("found {u.name}")            // found ann
    none => print("no such user")
  }

  let u = find(users, 1) else return              // or leave when it's missing
  print(u.name.upper())                           // ANN
}
```

- `x else fallback` is the value, or the fallback when it is missing.
- `x?.field`, `x?.f()` and `x?.0` are optional chaining: the result is missing when `x` is. Each
  step of a chain needs its own `?.`.
- `x!` unwraps, and panics on `none`. Use it only when missing is a bug.
- Many core functions return optionals instead of panicking: `xs.get(i)`, `xs.first()`,
  `xs.max()`, `m.get(k)`, `s.find(sub)`, `xs.find(pred)`.

## Errors: `T!`

```auk
fn parse_age(s: str): int! {
  let n = int.parse(s.trim()) else fail("not a number: {s}")
  if n < 0 { fail("negative age: {n}") }
  n
}

fn oldest(ages: [str]): int! {
  let ns = ages.map(a => parse_age(a))?    // every value, or the first error
  ns.max() else fail("no ages")
}

fn main() {
  print(oldest(["31", " 27", "45"]))       // ok(45)
  print(oldest(["31", "old"]))             // err(not a number: old)
  print(oldest(["31", "old"]) else -1)     // -1

  let n = oldest([]) else e => {           // else e => ... sees the error
    print("failed: {e}")                   // failed: no ages
    0
  }
  print(n)                                 // 0
}
```

The four tools:

- **`fail(e)`** returns an error from the current function. Its argument is a message, or an
  existing error.
- **`x?`** is the value of `x`, or returns `x`'s error from the current function. This is how
  errors travel upward: one character per call that can fail.
- **`x else fallback`** and **`x else e => ...`** handle the error here.
- **`match x { ok(v) => ..., err(e) => ... }`** when both paths need real code.

`?` on a list of results (`[T!]`) gives the list of values or the first error, which makes
"parse everything, stop at the first problem" one line.

To pass an error up and then call something on the value, parenthesize: `(fs.read(p)?).len()`.
`x?.f()` is optional chaining, which is for `T?` only.

The compiler does not let an error vanish. Using a `T!` where a `T` is expected is E0201
("missing `?`"), and calling a `T!` function and ignoring the result is E0334.

Add context as an error travels up by handling it and failing again:

```auk
fn read_config(path: str): str! uses fs {
  fs.read(path) else e => fail("config {path}: {e}")
}
```

An error from this function prints as
`config app.toml: fs.read app.toml: No such file or directory`.

### Errors and `main`

`main` may return `()!` or `int!`. An error that reaches the end of `main` is printed as
`error: <message>` on stderr and the program exits with status 1. With `int!`, the integer is
the exit status.

```auk
fn main(args: [str]): int! {
  if args.len() < 2 { fail("usage: tool <file>") }
  0
}
```

## Typed errors: `T!E`

When callers need to tell failures apart, make the error an enum:

```auk
enum ParseErr { BadToken(at: int), Eof }

fn parse(s: str): int!ParseErr {
  if s == "" { fail(Eof) }
  int.parse(s) else fail(BadToken(0))
}

fn double(s: str): int! {       // a plain T! function accepts any error through ?
  let n = parse(s)?
  n * 2
}

fn main() {
  match parse("") {
    ok(n) => print(n)
    err(Eof) => print("ran out of input")          // ran out of input
    err(BadToken(at)) => print("bad token at {at}")
  }
  match double("x") {                              // the typed error survived the T!
    err(BadToken(at)) => print("still a BadToken, at {at}")   // still a BadToken, at 0
    _ => print("something else")
  }
}
```

The `match` on a `T!E` is checked for exhaustiveness like any other, so a new error variant
shows you every place that must handle it.

`?` passes an `E` up through a function returning `T!E` (the same `E`) or plain `T!`. Between
two different error enums, translate explicitly: `read() else e => fail(Bad)`.

A good rule: libraries return `T!E` so their callers can react; applications mostly use plain
`T!` and let messages flow to the top.

## Mixing optionals and errors

`?` on an optional needs a function that returns an optional, and `?` on a result needs one
that returns a result. To cross over, say what the missing value means:

```auk
fn port(cfg: {str: str}): int! {
  let text = cfg.get("port") else fail("no port configured")   // optional -> error
  int.parse(text)?
}

fn main() {
  print(port({"port": "8080"}))   // ok(8080)
  print(port({}))                 // err(no port configured)
}
```

## Panics

A panic is a bug, not an error: integer overflow, an index out of range, `m[k]` for a missing
key, unwrapping `none`, a failed `assert` or `requires`, or reaching an unfilled `??` hole. It
prints the message and location and ends the program with status 101:

```console
panic: index 5 out of range for length 3
  at main.auk:8:9
```

Don't use panics for things that can legitimately happen, such as bad input or a missing file.
Those are errors, and belong in the return type.

`catch` is the boundary where a panic becomes an error, for code that must survive bugs in
what it calls, such as a server handling a request:

```auk
fn risky(xs: [int], i: int): int = xs[i] * 2

fn main() {
  let r = catch risky([1, 2, 3], 7)
  print(r)                                    // err(panic: index 7 out of range ... )
  let x = catch { risky([1, 2, 3], 1) } else 0
  print(x)                                    // 4
}
```

`catch e` has type `T!`. A postfix `?` or `!` after it applies to the whole `catch`, so
`catch f()?` passes the caught panic up as an error. `return` cannot leave a `catch` block.
For long-running programs, [supervisors](concurrency.md#supervisors) build on this.

Next: [Effects](effects.md).
