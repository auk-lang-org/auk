enum E { Bad(w: str), Worse }
fn typed(n: int): int!E {
  if n == 0 { fail(Bad("zero")) }
  if n < 0 { fail(Worse) }
  n
}
fn plain(n: int): int! = typed(n)?
fn show(r: int!): str = match r {
  err(Bad(why)) => "bad {why}"
  err(e) => "other {e}"
  ok(n) => "ok {n}"
}
fn main() {
  print(show(plain(0)))
  print(show(plain(-1)))
  print(show(plain(3)))
  print(typed(-1) is err(Worse))
  let v = typed(0) else e => match e { Bad(w) => w.len(), Worse => -1 }
  print(v)
  let m = plain(0) else e => -2
  print(m)
}
