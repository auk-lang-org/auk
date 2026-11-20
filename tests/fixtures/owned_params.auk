/// Owned parameters (design/ownership-plan.md, section 4): direct calls, function values,
/// closures, recursion, multiple clauses. The same output with AUK_NO_MOVES=1
/// (tests/runner/src/suite/ownership.auk).

struct Box { items: [str] }

fn add(xs: [int], x: int): [int] {
  var ys = xs
  ys.push(x)
  ys
}

fn both(a: [int], b: [int]): ([int], [int]) = (a, b)

fn wrap(xs: [int]): Box = Box { items: xs.map(x => "{x}") }

fn grow(b: Box, s: str): Box {
  var c = b
  c.items.push(s)
  c
}

fn relay(xs: [int], x: int): [int] = add(xs, x)

fn build(n: int, acc: [int]): [int] = if n == 0 { acc } else { build(n - 1, add(acc, n)) }

fn tag(n: int, s: [str]): [str] = if n == 0 { s } else { tag(n - 1, s + ["!"]) }
fn label(0, s: [str]): [str] = s
fn label(n: int, s: [str]): [str] = s + ["{n}"]

fn pick(xs: [str], keep: bool): [str] = if keep { xs } else { [] }

fn count_down(xs: [int]): [int] = match xs.len() {
  0 => xs
  _ => count_down(xs[1..xs.len()])
}

fn main() {
  // caller keeps using its value: the call retains
  let base = [1, 2]
  let more = add(base, 3)
  print(base)
  print(more)
  // the same value twice
  let t = both(base, base)
  print(t)
  // function values go through the borrowing entry
  let f = add
  print(f(base, 9))
  print([[1], [2]].map(xs => add(xs, 0)))
  print([[5]].reduce([], (acc, xs) => add(acc, xs[0])))
  // nested ownership, structs
  var bx = wrap([1, 2])
  bx = grow(bx, "z")
  print(bx)
  print(relay(base, 4))
  print(build(4, []))
  print(tag(2, ["t"]))
  print(label(0, ["a"]))
  print(label(2, ["a"]))
  print(pick(["a"], true))
  print(pick(["b"], false))
  print(count_down([1, 2, 3]))
  var v: [int] = []
  for i in 0..5 { v = add(v, i) }
  print(v)
}
