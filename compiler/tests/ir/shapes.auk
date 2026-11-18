// Shapes and derived instances: `any S` (vtables), derived Show/Eq/Ord/hash for structs,
// enums, tuples, optionals and results (as map keys, sorted, compared), to_value/from_value,
// a recursive struct (boxed field, copy-on-write through it), struct update, contracts
// (`requires`, `ensures` with `old` and `result`), peek, assert, imprints and constants.

shape Area {
  fn area(self): float
  fn name(self): str
}

struct Sq { side: float }

struct Circ { r: float }

fn area(s: Sq): float = s.side * s.side
fn name(s: Sq): str = "square"
fn area(c: Circ): float = c.r * c.r * 3.0
fn name(c: Circ): str = "circle"

enum Suit { Hearts, Spades, Joker(n: int) }

struct Card { suit: Suit, rank: int, tag: str? }

struct Tree { val: int, kids: [Tree], parent: Tree? }

struct Config { name: str, port: int, debug: bool, tags: [str], extra: {str: int} }

imprint SQUARES = [1, 2, 3, 4].map(x => x * x)
imprint TABLE: {str: int} = {"one": 1, "two": 2}
imprint CARD = Card { suit: Suit.Joker(7), rank: 1, tag: some("x") }
let GREETING = "hi " + "there"

fn cmp(a: Card, b: Card): int = a.rank - b.rank

fn total(shapes: [any Area]): float {
  var t = 0.0
  for s in shapes { t += s.area() }
  t
}

fn deposit(balance: var int, amount: int)
  requires amount > 0
  ensures balance == old(balance) + amount
{
  balance += amount
}

fn double(x: int): int ensures result == x * 2
fn double(0) = 0
fn double(x) = x * 2

fn main(): ()! {
  let shapes: [any Area] = [Sq { side: 2.0 }, Circ { r: 1.0 }]
  print(total(shapes))
  for s in shapes { print(s.name()) }
  let c1 = Card { suit: Suit.Hearts, rank: 3, tag: none }
  let c2 = Card { suit: Suit.Joker(1), rank: 2, tag: some("j") }
  let c3 = Card { rank: 9, ..c1 }
  print([(3, "b", [1]), (1, "a", [2]), (1, "a", [0, 1])].sort())
  print(c1 == c3)
  print((1, "x") < (1, "y"))
  print([c2, c1, c3].sort().map(c => c.rank))
  print(c1 < c2)
  var seen: {Card: int} = {}
  seen[c1] = 1
  seen[c2] = 2
  print(seen.get(c2))
  let tup: {(int, str?): bool} = {(1, some("a")): true}
  print(tup)
  let v = c2.to_value()
  print(v)
  let back: Card = from_value(v)?
  print(back)
  let cv = {"name": Value.Str("x"), "port": Value.Int(80), "debug": Value.Bool(true), "tags": Value.List([Value.Str("a")]), "extra": Value.Map({"k": Value.Int(1)})}
  let cfg: Config = from_value(Value.Map(cv))?
  print(cfg)
  var t = Tree { val: 1, kids: [Tree { val: 2, kids: [], parent: none }], parent: none }
  let t2 = Tree { val: 0, kids: [], parent: some(t) }
  t.parent = some(Tree { val: 9, kids: [], parent: none })
  print(t2.parent)
  print(t.parent?.val)
  var bal = 10
  deposit(&bal, 5)
  print(double(bal))
  print(SQUARES)
  print(TABLE["two"])
  print(CARD)
  print(GREETING)
  let p = peek c1.rank + 1
  assert p == 4
  assert c1.rank < 10
}

