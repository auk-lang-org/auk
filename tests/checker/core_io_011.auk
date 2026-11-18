fn main() uses rand {
  let a = rand.bytes(32)
  let b = rand.bytes(32)
  print("{a.len()} {a != b} {a.all(x => x >= 0 && x <= 255)}")
  let xs = [1, 2, 3, 4, 5, 6, 7, 8]
  let s = rand.shuffle(xs)
  print("{s.sort() == xs} {xs}")
  rand.seed(7)
  let s1 = rand.shuffle(xs)
  let c1 = rand.choice(xs)
  rand.seed(7)
  print("{rand.shuffle(xs) == s1} {rand.choice(xs) == c1}")
  let none_: [str] = []
  print(rand.choice(none_))
  print(rand.choice(["only"]))
  print(rand.shuffle(none_))
}
