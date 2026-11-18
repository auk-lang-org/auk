/// The package allows no effects (E0413 for each declared one), and has holes.
fn now(): int uses time = time.now()

fn wait(n: int): () uses time, env {
  time.sleep(n)
}

/// Twice `x`.
fn double(x: int): int
  requires x > 0
  ensures result > x
{
  ??
}

fn main() uses time {
  wait(now())
  print(double(2))
}

test "double" {
  assert double(2) == 4
}
