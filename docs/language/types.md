# Structs, enums and shapes

## Structs

```auk
struct Point { x: float, y: float }

fn main() {
  let p = Point { x: 1.0, y: 2.0 }
  let q = Point { x: 5.0, ..p }      // copy p, replacing x; ..p comes last
  let x = 0.0
  let y = 9.0
  let r = Point { x, y }             // shorthand for x: x, y: y
  print(p)                           // Point { x: 1.0, y: 2.0 }
  print(q.x + r.y)                   // 14.0
  print(p == Point { x: 1.0, y: 2.0 })   // true

  var m = p
  m.x = 100.0                        // fields of a var are assignable
  print("{m.x} {p.x}")               // 100.0 1.0: p is its own value
}
```

Every struct can be printed and compared with `==` without you writing anything. A struct is a
value like any other: assigning it copies it (cheaply), so `m` and `p` above are independent.

## Enums

An enum is a choice between variants, and each variant may carry fields:

```auk
enum Shape {
  Circle(r: float),
  Rect(w: float, h: float),
  Empty,
}

fn area(s: Shape): float = match s {
  Circle(r) => 3.14159 * r * r
  Rect(w, h) => w * h
  Empty => 0.0
}

fn main() {
  let shapes = [Circle(1.0), Rect(2.0, 3.0), Empty]
  print(shapes.map(s => area(s)))   // [3.14159, 6.0, 0.0]
  print(shapes[1])                  // Rect(2.0, 3.0)
}
```

Add a variant and every `match` and clause group that doesn't handle it stops compiling, each
with a message naming the missing case. That is the main reason to model a closed set of
alternatives as an enum.

Enums can be recursive, which is how trees are written:

```auk
enum Expr {
  Num(n: float),
  Add(a: Expr, b: Expr),
  Mul(a: Expr, b: Expr),
}

fn eval(Num(n)): float = n
fn eval(Add(a, b)): float = eval(a) + eval(b)
fn eval(Mul(a, b)): float = eval(a) * eval(b)

fn main() {
  print(eval(Add(Num(1.0), Mul(Num(2.0), Num(3.0)))))   // 7.0
}
```

A variant is written by its bare name wherever the expected type makes it clear. When it
doesn't, qualify it with the enum's name (`Shape.Empty`) or, from another module, with the
module's (`geo.Empty`).

## Optionals and results are ordinary types

`T?` is a value that may be missing, and `T!` is a value or an error. They have their own page,
[Errors and optionals](errors.md), because they come with dedicated syntax (`?`, `else`,
`?.`).

## Shapes: structural generics

A **shape** names a set of functions. Any type that has those functions fits the shape; there
is nothing to declare on the type.

```auk
shape Area { fn area(self): float }

struct Circle { r: float }
struct Square { side: float }

fn area(c: Circle): float = 3.14159 * c.r * c.r
fn area(s: Square): float = s.side * s.side

fn total(xs: [Area]): float = xs.map(x => x.area()).sum()

fn main() {
  print(total([Square { side: 2.0 }, Square { side: 3.0 }]))   // 13.0
  print(total([Circle { r: 1.0 }]))                            // 3.14159
}
```

A shape name used as a parameter type makes the function generic. The compiler makes one
copy of `total` for circles and one for squares, so there is no cost at run time, and nothing
is written at the call site.

Within one signature, **the same shape name means the same type**:

```auk
fn largest(a: Ord, b: Ord): Ord = if a > b { a } else { b }

fn main() {
  print(largest(3, 7))         // 7
  print(largest("pear", "fig"))   // pear
}
```

`largest(3, "x")` doesn't compile: both arguments and the result are one type. When you need
two independent types, name them:

```auk
fn pair<A: Show, B: Show>(a: A, b: B): str = "{a.show()} & {b.show()}"

fn main() {
  print(pair(1, "one"))   // 1 & one
}
```

### Mixed lists: `any`

`[Area]` is a list whose items all have one type. For a list of different types that share a
shape, write `any`:

```auk
shape Area { fn area(self): float }

struct Circle { r: float }
struct Square { side: float }

fn area(c: Circle): float = 3.14159 * c.r * c.r
fn area(s: Square): float = s.side * s.side

fn total(xs: [any Area]): float {
  var sum = 0.0
  for x in xs { sum += x.area() }
  sum
}

fn main() {
  let xs: [any Area] = [Circle { r: 1.0 }, Square { side: 2.0 }]
  print(total(xs))   // 7.14159
}
```

`any Area` calls `area` through a table at run time (dynamic dispatch). Prefer an enum when
you know all the cases; reach for `any` when the set is open, such as plugins or handlers.

### The built-in shapes

| shape | needs | gives you |
|---|---|---|
| `Show` | `fn show(self): str` | `print`, `str(x)`, `"{x}"` |
| `Eq` | `fn eq(self, o: Self): bool` | `==`, `!=`, `contains`, `unique`, map keys |
| `Ord` | `fn cmp(self, o: Self): int` (negative, zero or positive) | `<` `>` `sort` `min` `max` |
| `Data` | `to_value` / `from_value` | conversion to and from the neutral `Value` tree: JSON, TOML, CSV |

Every struct, enum and tuple gets `Show`, `Eq` and `Data` automatically. Tuples and lists also
compare element by element. Define the function yourself to override the derived one, or to
add `Ord`:

```auk
struct Card { rank: int, suit: char }

fn show(c: Card): str = "{c.rank}{c.suit}"          // replaces the derived Card { rank: .. }
fn cmp(a: Card, b: Card): int = a.rank - b.rank     // Card now fits Ord

fn main() {
  let hand = [Card { rank: 10, suit: 'h' }, Card { rank: 12, suit: 's' }, Card { rank: 7, suit: 'd' }]
  print(hand.sort())           // [7d, 10h, 12s]
  print(hand.max())            // some(12s)
  print(hand[0] < hand[1])     // true
}
```

To sort by a key without defining `cmp`, use `sort_by`; a tuple key sorts by several fields:

```auk
struct P { name: str, n: int }

fn main() {
  let ps = [P { name: "b", n: 2 }, P { name: "a", n: 2 }, P { name: "c", n: 9 }]
  print(ps.sort_by(p => (-p.n, p.name)).map(p => p.name))   // ["c", "a", "b"]
}
```

## Operators on your types

Define `add`, `sub`, `mul`, `div` or `mod` and the matching operator works:

```auk
struct Vec { x: float, y: float }

fn add(a: Vec, b: Vec): Vec = Vec { x: a.x + b.x, y: a.y + b.y }
fn mul(a: Vec, k: float): Vec = Vec { x: a.x * k, y: a.y * k }

fn main() {
  print((Vec { x: 1.0, y: 2.0 } + Vec { x: 0.5, y: 0.5 }) * 2.0)   // Vec { x: 3.0, y: 5.0 }
}
```

## Data: one conversion for every format

`Value` is core's neutral data tree:

```auk
enum Value { Null, Bool(b: bool), Int(i: int), Float(f: float), Str(s: str), List(xs: [Value]), Map(m: {str: Value}) }
```

The compiler derives `to_value(x)` and `from_value(v)` for every struct and enum. Format
packages only convert text to and from `Value`, so any type you write works with all of them:

```auk
struct Todo { id: int, title: str, done: bool }

fn main(): ()! {
  let t: Todo = json.decode("{{\"id\": 1, \"title\": \"write docs\", \"done\": false}}")?
  print(t.title)                                   // write docs
  print(json.encode(Todo { done: true, ..t }))     // {"done":true,"id":1,"title":"write docs"}
}
```

Note that the type comes from the annotation: type arguments are never written at a call.
(`json` is a package; add it with `raft add json`.)

## Sets

`Set<T>` is in core: `set([1, 2, 2])` builds one, with `contains`, `insert`, `remove`, `len`
and `to_list`. For most jobs `xs.unique()` or a map is enough.

Next: [Errors and optionals](errors.md).
