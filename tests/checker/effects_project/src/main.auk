/// The package allows `net` and `time`: `fs` is over the ceiling (E0413), `tme` is unknown
/// (E0414), and `geo` adds shapes and generic effects.
fn load(p: str): str! uses fs {
  fs.read(p)?
}

fn wait(): () uses tme, time {
  time.sleep(1)
}

fn stamp(): int uses time, rand = time.now()

fn main(): ()! uses fs, time {
  let s = load("x")?
  wait()
  print(geo.total([geo.Sq { s: 2.0 }]))
  print(s.len() + stamp())
}
