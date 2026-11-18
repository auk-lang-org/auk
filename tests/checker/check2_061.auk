fn f(): str! uses fs, rand {
  fs.read("x{rand.int(1, 2)}")
}
fn main() {}
