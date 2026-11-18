struct Leg { dist: float<km> }
fn twice<T>(x: T): (T, T) = (x, x)
fn main() {
  let l = Leg { dist: 2.0<km> }
  let probe: () = twice(l.dist)
}
