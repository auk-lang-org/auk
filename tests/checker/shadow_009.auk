fn f(o: [int]?): int {
  match o {
    some(env) => env.len()
    none => 0
  }
}
fn main() {}
