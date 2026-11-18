fn f(v: Value): int {
  match v {
    Null => 0
    Bool(b) => 1
    Int(i) => i
    Float(x) => 2
    Str(s) => 3
    List(xs) => 4
  }
}
fn main() {}
