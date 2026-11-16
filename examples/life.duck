/// Conway's Game of Life on a small grid.

fn parse(s: str): [[bool]] = s.lines().map(l => l.chars().map(c => c == '#'))

fn alive(g: [[bool]], y: int, x: int): int = if (g.get(y)?.get(x) else false) { 1 } else { 0 }

fn neighbors(g: [[bool]], y: int, x: int): int {
  var n = 0
  for dy in -1..=1 {
    for dx in -1..=1 {
      if (dy, dx) != (0, 0) { n += alive(g, y + dy, x + dx) }
    }
  }
  n
}

fn rule(true, 2): bool = true
fn rule(_, 3): bool = true
fn rule(_: bool, _: int): bool = false

fn step(g: [[bool]]): [[bool]] =
  g.enum().map((y, row) => row.enum().map((x, cell) => rule(cell, neighbors(g, y, x))))

fn show(g: [[bool]]): str =
  g.map(row => row.map(c => if c { '#' } else { '.' }).join("")).join("\n")

fn main() {
  var g = parse("""
    .....
    ..#..
    ..#..
    ..#..
    .....
    """)
  for _ in 0..3 {
    print(show(g) + "\n")
    g = step(g)
  }
}
