fn f(v: {str: int}): int {
  match v {
    {"b": n} => n
    {"a": n} => n + 1
    _ => 0
  }
}
fn g(v: {str: int}): int = match v { {"a": n} => n, _ => 0 }
fn h(v: Value): int {
  match v {
    Value.Null => 0
    {"a": Value.Int(n)} => n
    _ => 1
  }
}
fn main() {}
