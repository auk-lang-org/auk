/// Units of measure: the checker tracks `m`, `s`, `kg` through arithmetic, so a formula that
/// divides where it should multiply doesn't compile. Units are erased: plain doubles at run time.

struct Body { name: str, mass: float<kg>, speed: float<m/s> }

let g = 9.81<m/s^2>

fn fall_time(h: float<m>): float<s> = sqrt(2.0 * h / g)

fn kinetic(b: Body): float<kg*m^2/s^2> = 0.5 * b.mass * b.speed ** 2.0

fn km(x: float<m>): float<km> = x / 1000.0<m/km>

fn main() {
  let h = 20.0<m>
  let t = fall_time(h)
  print("a drop from {h} takes {t:.2}, hitting {g * t:.1}")
  let bodies = [
    Body { name: "ball", mass: 0.45<kg>, speed: 12.0<m/s> },
    Body { name: "car", mass: 1200.0<kg>, speed: 27.0<m/s> },
  ]
  for b in bodies {
    print("{b.name}: {kinetic(b):.1}")
  }
  let legs = [1200.0<m>, 800.0<m>, 2500.0<m>]
  print("walked {km(legs.sum())} in {legs.len()} legs, longest {legs.max()!}")
  print("as a plain number: {float(legs.sum()) / 1000.0}")
}

test "units cancel" {
  let ratio = 6.0<m> / 2.0<m>
  assert ratio == 3.0
  assert km(1500.0<m>) == 1.5<km>
  assert fall_time(0.0<m>) == 0.0<s>
}
