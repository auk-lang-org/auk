/// Shapes whose methods use effects: hidden effects of generic instances (E0410 with a call
/// chain), conversions to `any Area` (E0415).
pub shape Area {
  fn area(self): float
}

pub shape Loud {
  fn shout(self): str uses net
}

pub struct Sq { s: float }

pub fn area(q: Sq): float uses time {
  time.sleep(1)
  q.s * q.s
}

pub fn shout(q: Sq): str uses time {
  time.sleep(1)
  "sq"
}

pub fn total<T: Area>(xs: [T]): float {
  var t = 0.0
  for x in xs { t += x.area() }
  t
}

pub fn as_any(q: Sq): any Area = q

pub fn as_loud(q: Sq): any Loud = q

pub fn hear(l: any Loud): str = l.shout()
