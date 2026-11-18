// error: E0201 expected `int`, found `int!`
fn half(s: str): int! {
  let n: int = int.parse(s)
  n / 2
}

fn main() {
  print(half("8") else 0)
}
