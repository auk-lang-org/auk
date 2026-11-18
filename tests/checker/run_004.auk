fn kw(s: str): int = match s {
  "fn" => 1
  "let" => 2
  "var" => 3
  "if" => 4
  "else" => 5
  "" => 6
  "héllo" => 7
  "match" when s.len() > 100 => 98
  "match" => 8
  "matcha" => 9
  _ => 0
}

fn guarded(s: str, n: int): str = match s {
  "a" when n > 1 => "a big"
  "a" => "a small"
  "b" => "b"
  "c" => "c"
  "d" => "d"
  "e" => "e"
  x when x.starts_with("z") => "z-ish {x}"
  "f" => "f"
  _ => "other"
}

fn main() {
  for w in ["fn", "let", "var", "if", "else", "", "héllo", "match", "matcha", "matc", "x", "fnn", "f"] {
    print("{w}: {kw(w)}")
  }
  print([guarded("a", 2), guarded("a", 0), guarded("e", 0), guarded("zed", 0), guarded("f", 0), guarded("g", 0)])
}
