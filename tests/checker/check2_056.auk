fn load(p: str): str! uses fs, net {
  var c = net.tcp("a", 1)?
  c.close()
  fs.read(p)
}
fn main(): ()! uses net {
  var c = net.tcp("b", 2)?
  c.close()
}
