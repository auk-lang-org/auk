// error: E0205 an `if` without `else` has no value, but an `int` is expected here
fn sign(n: int): int {
  if n < 0 {
    return -1
  } else if n > 0 {
    return 1
  }
}

fn main() {}
