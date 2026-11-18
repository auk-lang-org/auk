
fn a(): tok.Tok? = Fn
fn b(): tok.Tok! = Float(1.5)
fn c(): tok.Tok!tok.Fail = Int(3)
fn d(x: bool): tok.Tok!tok.Fail = if x { Eof } else { fail(Bad("no")) }
fn e(x: int): tok.Tok!tok.Fail {
  if x > 0 { return Int(x) }
  match x { 0 => Fn, _ => Float(-1.0) }
}
fn f(): Value? = Int(7)
fn main() {
  let xs: [tok.Tok] = [Eof, Int(2)]
  print("{a()} {b()} {c()} {d(true)} {e(4)} {e(0)} {e(-1)} {f()} {xs}")
}
