struct Body { mass: float<kg>, speed: float<m/s> }

let g = 9.81<m/s^2>

fn fall(h: float<m>): float<s> = sqrt(2.0 * h / g)

fn energy(b: Body): float<kg*m^2/s^2> = 0.5 * b.mass * b.speed ** 2.0

fn main() {
  let xs = [1.0<m>, 2.0<m>]
  let b = Body { mass: 2.0<kg>, speed: 3.0<m/s> }
  print(fall(xs.sum() + 0.0<m>))
  print(energy(b) > 1.0<kg*m^2/s^2>)
  print(xs.max()!)
  print(5<px> * 2)
  print(float(g))
}
