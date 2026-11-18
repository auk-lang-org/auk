struct P { x: int?, y: str!, name: str }
fn check(n: int): ()! {
  if n < 0 { fail("negative") }
}
fn opt(n: int): ()? {
  if n == 0 { return none }
}
fn run(n: int): ()! {
  for i in 0..n { if i > 5 { fail("too many") } }
}
fn main() {
  let x = 3
  let y = "why"
  let name = "p"
  let p = P { x, y, name }
  print("{p.x} {p.y else "-"} {p.name}")
  print("{check(1) is ok(_)} {check(-1) is err(_)} {opt(0) is none} {opt(1) is some(_)}")
  print("{run(3) is ok(_)} {run(10) is err(_)}")
}
