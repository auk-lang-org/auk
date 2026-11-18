fn parse(s: str): int! {
  let n = int.parse(s) else fail("nan: {s}")
  n
}
fn main() {
  var names: [str] = []
  for i in 0..3 {
    let r = catch {
      names.push("a{i}")
      "v{parse("{i}")?}"
    }
    print(r)
  }
  print("{catch parse("q")} {names}")
}
