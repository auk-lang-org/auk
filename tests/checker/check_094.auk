fn main(): ()! {
  let r = regex("a+")?
  print(r.find("baa") else "")
  match regex("(") {
    err(Unclosed(at, _)) => print(at)
    _ => print(0)
  }
  let v = json.parse("[1]")?
  print(json.str(v))
}
