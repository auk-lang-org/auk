fn speed(d: float<m>, t: float<s>): float<m/s> = d / t

fn main() {
  let v = speed(3.0<m>, 2.0<s>)
  print("{v}")
}
