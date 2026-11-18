struct P { x: int }
fn main() {
  print("out")
  eprint("err {1 + 1}")
  eprint(P { x: 3 })
  print("out2")
}
