fn f(): str! uses fs {
  fs.read("x{rand.int(1, 2)}")
}
fn main() {}
