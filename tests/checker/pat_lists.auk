fn sum(xs: [int]): int = match xs {
  [] => 0
  [a] => a
  [a, b] => a + b
  [a, .., z] => a + z
  [a, b, c] => a + b + c
}

fn heads(xss: [[int]]): int = match xss {
  [[a, ..], [b]] => a + b
  [[], ..] => 0
}

fn pairs(xs: [(int, bool)]): int = match xs {
  [(n, true), .._] => n
  [(_, false)] => 1
}

fn tail([.., z]: [str]): str = z

fn tail2(xs: [str], [x, y]: [int]): int = x + y

fn main() {
  print(sum([1, 2]) + heads([[1]]) + pairs([]) + tail2([], [1, 2]))
  print(tail(["a"]))
}
