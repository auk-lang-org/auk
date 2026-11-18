fn f(v: {str: int}): str {
  match v {
    _ when false => ""
    {"a": n} => n
    _ => ""
  }
}
fn main() {}
