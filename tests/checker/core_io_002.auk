fn main(): ()! uses env {
  var n = 0
  while n < 2 {
    let l = env.read_line() else { break }
    print("line {l.len()}: {l}")
    n += 1
  }
  print("rest: {(env.read_all()?).trim()}")
  print(env.read_line())
  print((env.read_all()?).len())
}
