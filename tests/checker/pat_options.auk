enum E { Bad(code: int), Worse, Gone(why: str, at: int) }

fn o(x: int?): int = match x {
  some(0) => 0
  none => 1
}

fn r(x: int!E): int = match x {
  ok(n) => n
  err(Bad(1)) => 1
  err(Worse) => 2
}

fn plain(x: int!): int = match x {
  ok(n) => n
  err(Bad(c)) => c
  err(Gone(w, a)) => a
}

fn nested(x: (int?, bool)?): int = match x {
  some((some(n), true)) => n
  none => 0
}

async fn later(some(n): int?, acc: var int): int = n

fn many(none: (bool, bool)?, ok(0): int!E): int = 1

fn main() {
  print(o(none) + r(1) + plain(2) + nested(none) + many(none, 1))
}
