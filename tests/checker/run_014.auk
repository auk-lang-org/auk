struct A { n: int }
fn inc(a: var A)
  ensures a.n == old(a.n) + 1
{ a.n += 2 }
fn main() {
  var a = A { n: 1 }
  inc(&a)
}
