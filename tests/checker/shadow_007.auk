fn f(xs: {str: [int]}): int {
  var t = 0
  for k, proc in xs { t += proc.len() + k.len() }
  t
}
fn main() {}
