fn find(xs: [(str, int)], k: str): (str, int)? = xs.find((a, _) => a == k)
fn main() {
  let p: (int, str)? = some((1, "one"))
  let q: (int, str)? = none
  print("{p?.0} {p?.1} {q?.0} {q?.1}")
  let xs = [("ab", 1), ("cde", 2)]
  let ys: [(str, int)] = []
  print("{xs.first()?.0?.len()} {ys.first()?.0?.len()} {xs.last()?.0?.len() else 0}")
  print("{find(xs, "cde")?.1 else 0} {find(xs, "z")?.1 else 0}")
  let nested: ((int, int), str)? = some(((4, 5), "n"))
  print("{nested?.0?.1} {nested?.1?.len() else -1}")
  let oo: (int?, str)? = some((none, "x"))
  print("{oo?.0} {oo?.1} {oo?.0 else 9}")
  let owned: ([int], str)? = some(([1, 2, 3], "o"))
  let v = owned?.0 else []
  print("{v} {owned?.0?.len()}")
}
