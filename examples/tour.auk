/// A tour of Auk: most of the language in one small, deterministic program.

// ---- structs, enums and clauses ----

struct Point { x: float, y: float }

enum Shape { Circle(r: float), Rect(w: float, h: float), Poly(pts: [Point]) }

// A clause group: one clause per case, and the compiler rejects gaps.
fn area(Circle(r)): float = 3.0 * r * r
fn area(Rect(w, h)): float = w * h
fn area(Poly(pts)): float {
  var twice = 0.0
  for i, p in pts {
    let q = pts[(i + 1) % pts.len()]
    twice += p.x * q.y - q.x * p.y
  }
  twice.abs() / 2.0
}

fn describe(s: Shape): str = match s {
  Circle(r) => "circle of radius {r}"
  Rect(w, h) when w == h => "{w} square"
  Rect(w, h) => "{w} by {h} rectangle"
  Poly(pts) => "{pts.len()}-sided polygon"
}

// Guards and list patterns.
fn fizz(n: int): str when n % 15 == 0 = "FizzBuzz"
fn fizz(n: int): str when n % 3 == 0 = "Fizz"
fn fizz(n: int): str when n % 5 == 0 = "Buzz"
fn fizz(n: int): str = str(n)

fn total([]): int = 0
fn total([h, ..t]: [int]): int = h + total(t)

// ---- errors and optionals ----

fn parse_age(s: str): int! {
  let n = int.parse(s.trim()) else fail("not a number: {s}")
  if n < 0 { fail("negative age: {n}") }
  n
}

fn oldest(ages: [str]): int! {
  let ns = ages.map(a => parse_age(a))?  // every value, or the first error
  ns.max() else fail("no ages")
}

// ---- shapes: structural generics ----

struct Card { rank: int, suit: char }

fn show(c: Card): str = "{c.rank}{c.suit}"       // Card fits Show
fn cmp(a: Card, b: Card): int = a.rank - b.rank  // ... and Ord

fn best(xs: [Ord]): Ord? = xs.max()

// ---- var parameters and contracts ----

fn bump(n: var int, by: int) { n += by }

fn isqrt(n: int): int
  requires n >= 0
  ensures result * result <= n
{
  var r = 0
  while (r + 1) * (r + 1) <= n { r += 1 }
  r
}

fn main() {
  // let is immutable, var is mutable; types are inferred
  let answer = 42
  var count = 0
  bump(&count, 3)
  count.bump(4)
  print("count = {count}")

  // no implicit conversions between int and float
  print(float(answer) / 8.0)
  print(int(9.99))
  print("sqrt(2) = {2.0.sqrt():.4}")

  // strings interpolate any expression, with optional formatting
  let name = "auk"
  print("hello, {name.upper()}: {name.len()} chars [{name:>6}] [{name:<6}]")

  // shapes and clauses
  let shapes = [
    Circle(1.0),
    Rect(2.0, 2.0),
    Rect(2.0, 3.0),
    Poly([Point { x: 0.0, y: 0.0 }, Point { x: 4.0, y: 0.0 }, Point { x: 0.0, y: 3.0 }]),
  ]
  for s in shapes {
    print("{describe(s):<22} area {area(s)}")
  }
  print((1..=15).map(n => fizz(n)).join(" "))
  print(total([1, 2, 3, 4]))

  // lists, closures and pipelines
  let xs = [5, 3, 8, 1, 9, 2]
  let odd_squares = xs.filter(x => x % 2 == 1).map(x => x * x)
  print(odd_squares.join(", "))
  print(xs |> sort() |> take(3) |> join(" < "))
  print(xs.reduce(0, (acc, x) => acc + x))

  // maps keep insertion order
  var stock = {"apple": 3, "pear": 0}
  stock["fig"] = 12
  stock["apple"] += 1
  for k, v in stock {
    print("{k}: {v}")
  }
  print(stock.get("kiwi") else -1)

  // tuples and patterns
  let (q, r) = (17 / 5, 17 % 5)
  print("17 = 5 * {q} + {r}")
  let [first, .., last] = xs else return
  print("first {first}, last {last}")

  // errors: ? passes them up, else handles them
  print(oldest(["31", " 27", "45"]) else -1)
  match oldest(["31", "old"]) {
    ok(n) => print("oldest: {n}")
    err(e) => print("error: {e}")
  }

  // optionals
  let cards = [
    Card { rank: 10, suit: 'h' },
    Card { rank: 12, suit: 's' },
    Card { rank: 7, suit: 'd' },
  ]
  print(best(cards)?.show() else "no cards")
  let no_cards: [Card] = []
  print(best(no_cards)?.show() else "no cards")

  // if, match and loop are expressions
  var i = 0
  let first_big = loop {
    i += 1
    if i * i > 50 { break i }
  }
  let size = if first_big > 5 { "big" } else { "small" }
  print("{first_big} is {size}; isqrt(50) = {isqrt(50)}")
}

test "tour" {
  assert fizz(9) == "Fizz"
  assert area(Rect(2.0, 3.0)) == 6.0
  assert oldest(["1", "x"]) is err(_)
  assert isqrt(99) == 9
}
