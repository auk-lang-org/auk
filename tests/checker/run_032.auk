struct A { v: int, b: B }
struct B { v: int, c: C, xs: [int] }
struct C { v: int, a: A? }
struct Emp { name: str, pay: int, boss: Boss }
struct Boss { name: str, pay: int, up: Emp? }
fn raise(e: var Emp) { e.boss.pay += 100 }
fn main() {
  let x = A { v: 1, b: B { v: 2, c: C { v: 3, a: none }, xs: [1] } }
  var y = x
  y.b.c.v += 10
  y.b.v = 20
  y.b.xs.push(2)
  y.b.xs[0] = 9
  print("{x.b.v} {x.b.c.v} {x.b.xs} | {y.b.v} {y.b.c.v} {y.b.xs}")
  let e = Emp { name: "ann", pay: 1, boss: Boss { name: "bob", pay: 10, up: none } }
  var f = e
  f.boss.name = "carl"
  raise(&f)
  var g = f
  g.boss.pay = 0
  g.boss = Boss { name: "dee", pay: 5, up: some(e) }
  print("{e.boss.name} {e.boss.pay} | {f.boss.name} {f.boss.pay} | {g.boss.name} {g.boss.pay}")
}
