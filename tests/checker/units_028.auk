struct Leg { name: str, dist: float<km> }

fn main() {
  let d = 3.0<m>
  let t = 2.0<s>
  let n = 5<px>
  print("{d} {d / t / t} {n} {d:.2} {d * 3.0<kg> / (t * t)} {float(d)} {d / d}")
  print(d)
  print(str(d))
  print(to_value(Leg { name: "a", dist: 1.5<km> }))
  print([1.0<m>, 2.0<m>])
}
