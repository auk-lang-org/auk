fn main(): int uses proc {
  let xs = ["a", "b"]
  let m = {"k": xs}
  print("before {m}")
  if xs.len() == 2 { proc.exit(3) }
  print("after")
  0
}
