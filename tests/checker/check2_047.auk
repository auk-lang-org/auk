shape Area { fn area(self): float }
struct Sq { s: float }
fn area(q: Sq): float uses fs {
  let _ = fs.read("x") else ""
  q.s * q.s
}
fn total(xs: [Area]): float = xs.map(x => x.area()).sum()
fn main() {
  print(total([Sq { s: 1.0 }]))
}
