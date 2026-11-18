fn f(x: int): int = peek x * 2
test "io" {
  let s = fs.read("x") else ""
  print(s)
  assert time.now() > 0
}
fn main() { print(f(1)) }
