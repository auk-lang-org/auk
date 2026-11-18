/// A point "here"	(tab), café.
struct Pt { x: int, y: int }

enum Msg { Move(to: Pt), Say(text: str), Quit }

shape Named {
  fn name(self): str
}

/// Header with contracts; clauses follow.
pub fn step(m: Msg, n: int): int
  requires n >= 0
fn step(Move(Pt { x, y }), n: int): int {
  let d = x + y
  if d > n {
    let far = d - n
    ??
  } else {
    match n {
      0 => ??
      k when k > ?? => k
      _ => d
    }
  }
}
fn step(Say(text), n: int): int = text.len() + ??
fn step(Quit, var_n: int): int {
  for i, p in [Pt { x: 1, y: 2 }] {
    let Pt { x, .. } = p
    var acc = i + x
    acc += ??
  }
  let parsed = int.parse("1") else e => ??
  let r: int = int.parse("2") else {
    ??
  }
  [1, 2].map(z => z + var_n + ??).len()
}

fn later(): int! {
  let v = ??
  v
}

let ANSWER: int = 40 + ??

imprint TABLE: [int] = [??, 2]

test "step" {
  let m = Msg.Quit
  assert step(m, 1) == ??
}

test "unrelated" {
  { ?? }
}

fn main() {
  print(step(Msg.Quit, 1))
}
