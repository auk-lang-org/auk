// Control flow and the 2d lowerings: or-patterns, tuple assignment, a `match` on `str` by
// table, `s += x` / `s = s + x`, `str(cs[a..b])`, moving an element out and back, the fused
// map update, borrowed element reads, self tail calls (with a `var` parameter), loops with
// values, labels of `break`/`continue`, `?` / `else` / `?.` and list `?`.

enum Tok { LParen, RParen, Num(n: int), Word(w: str), Name(w: str), Eof }

struct Group { name: str, items: [str] }

struct Node { val: int, next: Node? }

fn kind(t: Tok): str = match t {
  LParen | RParen => "paren"
  Num(n) when n > 100 => "big {n}"
  Num(n) => "num {n}"
  Word(w) | Name(w) => "word {w}"
  Eof => "eof"
}

fn keyword(s: str): int = match s {
  "fn" => 1
  "let" => 2
  "var" => 3
  "if" => 4
  "else" => 5
  "match" => 6
  "while" => 7
  "for" => 8
  _ => 0
}

fn sum_to(n: int, acc: int): int = if n == 0 { acc } else { sum_to(n - 1, acc + n) }

fn count_down(n: int, log: var [int]) {
  if n == 0 { return }
  log.push(n)
  count_down(n - 1, &log)
}

fn first_even(xs: [int]): int? {
  for x in xs {
    if x % 2 == 0 { return x }
  }
  none
}

fn halves(xs: [int]): [int]? {
  let hs = xs.map(x => if x % 2 == 0 { some(x / 2) } else { none })
  hs?
}

fn parse_all(xs: [str]): [int]! {
  let ns = xs.map(x => int.parse(x))
  ns?
}

fn len_of(n: Node?): int = n?.val else -1

fn main(): ()! {
  print([Tok.LParen, Tok.Num(3), Tok.Num(300), Tok.Word("x"), Tok.Eof].map(kind))
  print(["fn", "let", "while", "nope", "else"].map(keyword))
  var a = 1
  var b = 2
  (a, b) = (b, a)
  print("{a} {b}")
  var s = ""
  for i in 0..5 {
    s += "{i}"
    s = s + ","
  }
  print(s)
  let cs = "hello world".chars()
  print(str(cs[0..5]))
  print(str(cs[6..=10]))
  var groups = [Group { name: "a", items: [] }, Group { name: "b", items: [] }]
  for k in 0..3 {
    var g = groups[1]
    g.items.push("x{k}")
    groups[1] = g
  }
  print(groups[1].items)
  var counts: {str: int} = {}
  for w in ["a", "b", "a", "c", "a"] { counts[w] = (counts.get(w) else 0) + 1 }
  print(counts["a"])
  var weights: {str: float} = {}
  let one = 1.5
  let w = "x"
  weights[w] = (weights.get(w) else 0.0) * one
  print(weights)
  if groups[0].name == "a" && groups[1].items.len() == 3 { print("ok") }
  print(sum_to(100, 0))
  var log: [int] = []
  count_down(3, &log)
  print(log)
  print(first_even([1, 3, 4, 5]))
  print(halves([2, 4]))
  print(halves([2, 3]))
  print(parse_all(["1", "2"]))
  let bad = parse_all(["1", "x"]) else e => {
    print("bad: {e}")
    []
  }
  print(bad)
  let node = Node { val: 7, next: some(Node { val: 8, next: none }) }
  print(len_of(node.next))
  print(len_of(none))
  var i = 0
  let found = loop {
    i += 1
    if i % 7 == 0 { break i }
    if i > 100 { break -1 }
  }
  print(found)
  var j = 0
  while j < 10 {
    j += 1
    if j % 2 == 0 { continue }
    if j > 7 { break }
  }
  let n = int.parse("42")?
  let Num(m) = Tok.Num(n) else { return }
  print(m)
  let t: Tok? = some(Tok.Word("w"))
  let p: (int, str)? = some((1, "q"))
  print(p?.1)
  print(t)
}
