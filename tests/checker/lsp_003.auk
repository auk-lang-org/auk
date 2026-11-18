/// Adds two numbers.
fn add(a: int, b: int): int = a + b

fn bump(n: var int) { n += 1 }

fn main() {
  let total = add(1, 2)
  let pair: (str, int) = ("🦆", 2)
  var y = 1
  bump(&y)
  print("{total} {pair.0} {util.double(total)} {y}")
}
