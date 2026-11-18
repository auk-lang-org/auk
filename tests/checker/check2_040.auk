fn f(): int uses fs {
  let s = fs.read("x") else ""
  s.len() + time.now()
}
fn main() {}
