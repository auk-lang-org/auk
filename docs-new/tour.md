# A tour of Auk

This page builds one small program, an inventory tool, and meets most of the language along
the way. Each step is a complete program you can run with `auk run`. For depth on any topic,
follow the links to the [language guide](README.md#the-language).

## 1. Data

```auk
struct Item { name: str, qty: int, price: float }

fn main() {
  let items = [
    Item { name: "bolt", qty: 120, price: 0.25 },
    Item { name: "gear", qty: 8, price: 12.5 },
    Item { name: "belt", qty: 0, price: 30.0 },
  ]
  for item in items {
    print("{item.name:<6} {item.qty:>4} @ {item.price:.2}")
  }
  let value = items.map(i => float(i.qty) * i.price).sum()
  print("stock value: {value:.2}")       // stock value: 130.00
  print(items[1])                        // Item { name: "gear", qty: 8, price: 12.5 }
}
```

- `let` is immutable; `var` is mutable. Types are inferred inside functions.
- Strings interpolate expressions, with optional formatting after a colon.
- There are no implicit conversions: `float(i.qty)` is explicit.
- `i => ...` is a closure, and `x.f()` calls any function whose first parameter fits `x`.
- Structs print and compare without any code from you.

More: [Basics](language/basics.md).

## 2. Choices, and functions by cases

```auk
struct Item { name: str, qty: int, price: float }

enum Level { Out, Low(left: int), Fine }

fn level(item: Item): Level {
  if item.qty == 0 { Out } else if item.qty < 10 { Low(item.qty) } else { Fine }
}

fn advice(Out): str = "reorder now"
fn advice(Low(left)): str = "only {left} left"
fn advice(Fine): str = "ok"

fn main() {
  let gear = Item { name: "gear", qty: 8, price: 12.5 }
  print(advice(level(gear)))         // only 8 left
  print(gear.level().advice())       // the same, read left to right
}
```

`advice` is written as **clauses**, one per case. The compiler checks that the clauses cover
every `Level`. Add a variant to the enum and this function stops compiling until you handle
it. The same checking applies to `match`.

More: [Functions, clauses and patterns](language/functions.md),
[Structs, enums and shapes](language/types.md).

## 3. Things that can fail

A line of input may be malformed. The return type says so: `Item!` is "an `Item`, or an
error".

```auk
struct Item { name: str, qty: int, price: float }

fn parse_item(line: str): Item! {
  let [name, qty, price] = line.split(",") else fail("expected name,qty,price: {line}")
  let qty = int.parse(qty.trim())?
  if qty < 0 { fail("negative quantity for {name}") }
  Item { name: name.trim(), qty, price: float.parse(price.trim())? }
}

fn parse_all(text: str): [Item]! = text.lines().map(l => parse_item(l))?

fn main() {
  print(parse_all("bolt, 120, 0.25\ngear, 8, 12.5"))
  print(parse_all("bolt, 120, 0.25\ngear, -1, 12.5"))   // err(negative quantity for gear)

  let items = parse_all("oops") else e => {
    print("could not read stock: {e}")
    []
  }
  print(items.len())                                    // 0
}
```

- `fail(...)` returns an error. `x?` passes one up. `x else ...` handles one.
- `let [a, b, c] = ... else ...` is a pattern that might not match, with what to do when it
  doesn't.
- `?` on a list of results gives every value, or the first error.
- There are no exceptions and no `null`. A value that may be missing is a `T?`.

More: [Errors and optionals](language/errors.md).

## 4. The outside world

Reading a file is an **effect**, and functions that have effects declare them:

```auk
struct Item { name: str, qty: int, price: float }

fn parse_item(line: str): Item! {
  let [name, qty, price] = line.split(",") else fail("expected name,qty,price: {line}")
  Item { name: name.trim(), qty: int.parse(qty.trim())?, price: float.parse(price.trim())? }
}

fn load(path: str): [Item]! uses fs {
  let lines = fs.lines(path)?
  lines.map(l => parse_item(l))?
}

fn main(args: [str]): int! uses fs {
  let path = args.get(1) else fail("usage: stock <file>")
  let items = load(path)?
  print("{items.len()} items, {items.filter(i => i.qty == 0).len()} out of stock")
  0
}
```

`parse_item` has no `uses`, so it is pure, guaranteed: it cannot read a file, the clock or the
network. `load` reads files and says so, and so must everything that calls it. An error that
reaches the end of `main` is printed, and the program exits with status 1.

A project's manifest lists the effects the whole program may use, dependencies included.

More: [Effects](language/effects.md), [Modules and packages](language/modules.md).

## 5. Checking your work

```auk
struct Item { name: str, qty: int, price: float }

fn take(item: Item, n: int): Item
  requires n > 0 && n <= item.qty
  ensures result.qty == item.qty - n
{
  Item { qty: item.qty - n, ..item }
}

fn restock_cost(item: Item, target: int): float { ?? }   // not written yet

test "take removes stock" {
  let bolt = Item { name: "bolt", qty: 10, price: 0.25 }
  assert take(bolt, 3).qty == 7
  assert take(bolt, 3).name == "bolt"
}
```

- `test` blocks sit next to the code; `auk test` runs them.
- `requires` and `ensures` are contracts, checked as the program runs.
- `??` is a hole: the program type-checks and its tests run, but `auk build` won't ship it.

More: [Tests, contracts and holes](language/testing.md).

## 6. Doing several things at once

```auk
async fn price_from(supplier: str, ms: int): (str, float) uses time {
  time.sleep(ms)                       // stands in for a network request
  (supplier, 10.0 + float(ms) / 100.0)
}

fn main() uses time {
  let quotes = await [
    price_from("acme", 30),
    price_from("bolt-co", 10),
    price_from("gearhaus", 20),
  ]
  let best = quotes.sort_by(q => q.1).first()
  print(best)                          // some(("bolt-co", 10.1))
}
```

An `async fn` can run as a task; `await` on a list runs them all concurrently. Tasks share no
memory, so there are no data races, and a task that crashes can be restarted by a supervisor.

More: [Concurrency](language/concurrency.md).

## 7. Numbers that mean something

```auk
struct Crate { weight: float<kg>, volume: float<m^3> }

fn density(c: Crate): float<kg/m^3> = c.weight / c.volume

fn main() {
  let c = Crate { weight: 240.0<kg>, volume: 0.8<m^3> }
  print("{density(c)}")                // 300.0 kg/m^3
}
```

Units are checked at compile time and cost nothing at run time. Writing `c.volume / c.weight`
by mistake is a compile error.

More: [Units of measure](language/units.md).

## What you didn't see

No imports, no semicolons, no `null`, no exceptions, no type arguments at call sites, no
inheritance, no build configuration. `examples/tour.auk` in the repository is a longer program
in the same spirit, and `auk spec` prints the entire language on a few screens.
