/// Programs whose locals are moved at their last use (design/ownership-plan.md): the same
/// output with AUK_NO_MOVES=1 (tests/runner/src/suite/ownership.auk).

struct P { name: str, xs: [int] }
enum T { Leaf, Node(l: T, v: int, r: T) }

fn ins(t: T, v: int): T = match t {
  Leaf => Node(Leaf, v, Leaf)
  Node(l, x, r) when v < x => Node(ins(l, v), x, r)
  Node(l, x, r) when v > x => Node(l, x, ins(r, v))
  _ => t
}

fn sum(t: T): int = match t {
  Leaf => 0
  Node(l, v, r) => sum(l) + v + sum(r)
}

fn count(xs: [str], acc: [str], n: int): [str] = if n == 0 { acc } else {
  var a = acc
  a.push(xs[n % xs.len()])
  count(xs, a, n - 1)
}

fn pick(c: bool, a: [int], b: [int]): [int] {
  var x = a
  var y = b
  if c { return x }
  let z = y
  z
}

fn main() {
  // loop back edge: v read each iteration
  var v: [int] = []
  var keep: [[int]] = []
  for i in 0..5 {
    var w = v
    w.push(i)
    keep.push(v)
    v = w
  }
  print(v)
  print(keep)
  // moved on one branch only
  var s = "abc"
  var out: [str] = []
  for i in 0..4 {
    let t = s + "{i}"
    if i % 2 == 0 {
      out.push(t)
    } else {
      out.push(t + "!")
      print(t)
    }
  }
  print(out)
  // a write later in the same statement
  var xs = [1, 2]
  var ys = [3]
  let pr = (xs.len(), {
    xs = ys
    1
  }, xs)
  print(pr)
  // match root pinned
  var tr = Leaf
  for k in [5, 3, 8, 1, 4] { tr = ins(tr, k) }
  let tr2 = tr
  match tr {
    Node(l, _, _) => {
      let moved = tr
      print(sum(l) + sum(moved))
    }
    Leaf => {}
  }
  print(sum(tr2))
  // closures capture
  var names = ["a", "b"]
  let f = (x: str) => names.len() + x.len()
  names.push("c")
  print(f("zz"))
  print(names)
  // catch
  var cs = [1]
  let r = catch {
    cs.push(2)
    cs.len()
  }
  print(r)
  print(cs)
  // shadowing
  let q = [1, 2, 3]
  let q2 = q
  let q = [9]
  print(q2)
  print(q)
  // struct shorthand
  let name = "n"
  var ys2 = [7]
  let p = P { name, xs: ys2 }
  print(p)
  print(name)
  // while condition, break value
  var acc: [int] = []
  var k = 0
  while acc.len() < 3 {
    var a2 = acc
    a2.push(k)
    acc = a2
    k += 1
  }
  let found = loop {
    let c2 = acc
    if c2.len() > 0 { break c2 }
  }
  print(found)
  print(acc)
  // tail-call function with owned params
  print(count(["x", "y"], [], 5))
  print(pick(true, [1], [2]))
  print(pick(false, [1], [2]))
  // else arm
  let m: {int: [int]} = {1: [1]}
  let dflt = [0]
  let got = m.get(2) else dflt
  print(got)
  print(dflt)
  // string building moved
  var str_acc = ""
  for i in 0..3 {
    var t = str_acc
    t += "{i}"
    str_acc = t
  }
  print(str_acc)
  // a binding of the whole matched value is the matched variable: moving it would empty both
  let whole: [int]? = some([4])
  let first = match whole {
    some(_) when str_acc == "" => some([0])
    w => w
  }
  print(first)
  print(whole)
}
