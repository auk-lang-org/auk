// error: E0335 `return` can't leave a `catch`
fn first(xs: [int]): int {
  let v = catch {
    return xs[0]
  }
  v else 0
}

fn main() {
  print(first([1]))
}
