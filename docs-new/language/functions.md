# Functions, clauses and patterns

## Functions

```auk
fn add(a: int, b: int): int = a + b       // a one-expression body

fn greet(name: str) {                     // no result: the return type is left out
  print("hi {name}")
}

fn classify(n: int): str {                // the last expression is the result
  if n < 0 { return "negative" }
  if n == 0 { "zero" } else { "positive" }
}

fn main() {
  greet("ann")                // hi ann
  print(add(2, 3))            // 5
  print(classify(-4))         // negative
}
```

Parameter and return types are always written; everything inside the body is inferred. `pub`
makes a function visible to other modules (see [Modules](modules.md)).

### Dot calls and pipes

`x.f(a)` means `f(x, a)`. Any function can be called with a dot on its first argument, so
there are no methods to declare and no difference between "your" functions and the built-in
ones:

```auk
struct Card { rank: int, suit: char }

fn label(c: Card): str = "{c.rank}{c.suit}"
fn beats(a: Card, b: Card): bool = a.rank > b.rank

fn main() {
  let c = Card { rank: 12, suit: 's' }
  print(label(c))                                // 12s
  print(c.label())                               // 12s: the same call
  print(c.beats(Card { rank: 7, suit: 'd' }))    // true
}
```

`x |> f(a)` also means `f(x, a)`. It reads well for a pipeline of free functions; don't mix
`.` and `|>` in one chain.

```auk
print([5, 3, 8, 1] |> sort() |> take(2) |> join(" < "))   // 1 < 3
```

### Overloading

Two functions may share a name when they differ in parameter count or in the type of the
first parameter. That is what makes dot calls work across types:

```auk
struct Item { name: str }
struct Order { id: int }

fn describe(i: Item): str = "item {i.name}"
fn describe(o: Order): str = "order #{o.id}"

fn main() {
  print(Item { name: "pen" }.describe())   // item pen
  print(Order { id: 7 }.describe())        // order #7
}
```

### Closures

```auk
let double = x => x * 2
let add = (a: int, b: int) => a + b   // annotate when nothing else gives the types
let noisy = x => {
  print("got {x}")
  x + 1
}
print(double(4))        // 8
print(add(1, 2))        // 3
print(noisy(1))         // got 1, then 2

let base = 10
print([1, 2].map(x => x + base))                              // [11, 12]: closures capture values
print(["a", "b"].enum().map((i, s) => "{i}{s}"))              // ["0a", "1b"]: a pair unpacks
```

A function type is written `(A, B) => R`:

```auk
fn twice(f: (int) => int, x: int): int = f(f(x))

fn main() {
  print(twice(x => x * 3, 2))   // 18
}
```

A closure captures by value and cannot assign to a captured variable. To accumulate, use
`reduce`, or a plain loop.

### `var` parameters

Arguments are passed as values, so a function cannot change its caller's variables. A `var`
parameter is the exception, and the caller marks it with `&` so the change is visible where it
happens:

```auk
fn bump(n: var int, by: int) { n += by }

fn main() {
  var count = 0
  bump(&count, 3)
  count.bump(4)        // a dot call needs no &
  print(count)         // 7
}
```

This is how a parser threads its position and how a function fills a list in place, without
returning a tuple from everything.

## Clauses

A function can be written as several **clauses**, each matching its arguments against
patterns. Clauses are tried top to bottom, and the compiler rejects the function unless they
cover every possible argument.

```auk
fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)

enum Shape { Circle(r: float), Rect(w: float, h: float) }

fn area(Circle(r)): float = 3.14159 * r * r
fn area(Rect(w, h)): float = w * h

fn main() {
  print(fib(20))                 // 6765
  print(area(Rect(2.0, 3.0)))    // 6.0
}
```

When a pattern makes the parameter's type obvious (`0`, `Circle(r)`), the annotation is left
out. When it doesn't, write the type after the pattern:

```auk
fn total([]): int = 0
fn total([h, ..t]: [int]): int = h + total(t)

fn main() {
  print(total([1, 2, 3, 4]))   // 10
}
```

A **guard** adds a condition to a clause:

```auk
fn grade(n: int): str when n >= 90 = "A"
fn grade(n: int): str when n >= 80 = "B"
fn grade(_: int): str = "C"

fn main() {
  print([95, 85, 20].map(n => grade(n)))   // ["A", "B", "C"]
}
```

The rules:

- The clauses of one function must be next to each other, with the same name and parameter
  count.
- Guards must be pure and cannot fail.
- A clause that can never be reached is an error (E0401), as is a missing case (E0400). The
  missing-case error names an example the clauses don't handle and offers the clause to add.
- A recursive call in tail position becomes a loop, so `fn len([_, ..t]: [int], acc: int): int
  = len(t, acc + 1)` runs in constant stack space.

Clauses with literal patterns are also how routing and command dispatch are usually written:

```auk
fn route("GET", "/"): str = "home"
fn route("GET", "/users/" + id): str = "user {id}"
fn route(method: str, path: str): str = "404 for {method} {path}"

fn main() {
  print(route("GET", "/users/42"))   // user 42
  print(route("PUT", "/x"))          // 404 for PUT /x
}
```

An optional header line before the clauses carries what applies to all of them: a doc comment,
`pub`, or [contracts](testing.md#contracts).

```auk
/// The n-th Fibonacci number.
pub fn fib(n: int): int
  requires n >= 0
fn fib(0): int = 0
fn fib(1): int = 1
fn fib(n: int): int = fib(n - 1) + fib(n - 2)
```

## Patterns

The same patterns work in clauses, in `match`, in `let`, in `for`, and with `is`.

| pattern | matches |
|---|---|
| `0` `"GET"` `'c'` `true` | that literal |
| `_` | anything |
| `x` | anything, bound to `x` |
| `Circle(r)` | that enum variant, binding its fields |
| `(a, b)` | a tuple |
| `[]` `[a, b]` | a list of exactly that length |
| `[h, ..t]` `[.., last]` `[first, .., last]` | a list with a rest |
| `User { name, .. }` | a struct; `..` skips the other fields |
| `{"k": v}` | a map with that key (other keys allowed) |
| `"GET " + rest` | a string with that prefix |
| `some(v)` `none` | an optional |
| `ok(v)` `err(e)` | a result |
| `A \| B(x)` | either; every alternative binds the same names |

A bare name that is an enum variant in scope (`Eof`) matches that variant; any other name
binds.

```auk
struct User { name: str, age: int, admin: bool }

fn main() {
  let u = User { name: "ann", age: 31, admin: true }

  let User { name, age, .. } = u            // destructuring
  print("{name} is {age}")                  // ann is 31

  let (q, r) = (17 / 5, 17 % 5)
  print("{q} r {r}")                        // 3 r 2

  print(u is User { admin: true, .. })      // true: `is` tests a pattern

  let words = "the quick brown fox".split()
  let [first, .., last] = words else return   // might not match: the else must leave
  print("{first} ... {last}")               // the ... fox

  for i, (k, v) in [("a", 1), ("b", 2)] {   // index, then a pattern
    print("{i}: {k}={v}")
  }
}
```

A `let` whose pattern might not match needs an `else` that leaves the block (`return`,
`break`, `continue`, `fail(...)` or a panic). A pattern that always matches needs none.

In `match`, arms are separated by newlines or commas and may have guards:

```auk
enum Shape { Circle(r: float), Rect(w: float, h: float) }

fn describe(s: Shape): str = match s {
  Circle(r) => "circle of radius {r}"
  Rect(w, h) when w == h => "{w} square"
  Rect(w, h) => "{w} by {h} rectangle"
}

fn main() {
  print(describe(Rect(2.0, 2.0)))   // 2.0 square
}
```

One wrinkle: a struct literal or an `else` inside the head of an `if`, `while`, `for` or
`match` needs parentheses, because `{` would otherwise start the block.

Next: [Structs, enums and shapes](types.md).
