fn sign(n: int): str = match n {
  -1 => "neg"
  0 => "zero"
  1 => "pos"
  -1 => "again"
}

fn temp(x: float): str = match x {
  0.0 => "zero"
  -0.5 => "cold"
  1.5 => "warm"
}

fn letter(c: char): int = match c {
  'a' => 1
  'b' => 2
  'a' => 3
}

fn route(s: str): int = match s {
  "GET /" => 1
  "GET " + rest => 2
  "POST " + body => body.len()
  "GET /" => 4
}

fn flags(a: bool, b: bool): int = match (a, b) {
  (true, true) => 1
  (false, _) => 2
}

fn tri(true, x: int): int = x
fn tri(false, 0): int = 0

fn main() {
  print(sign(1))
  print(letter('a') + route("GET /") + flags(true, false) + tri(true, 1))
  print(temp(0.0))
}
