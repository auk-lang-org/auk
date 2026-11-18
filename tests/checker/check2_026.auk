fn f(v: Value): int {
  match v {
    Map({"a": Int(n)}) => n
    Null => 0
  }
}
fn main() {}
