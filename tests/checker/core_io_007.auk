fn die(n: int): int uses proc = proc.exit(n)
fn main() uses proc {
  eprint("bye")
  print(die(42))
}
