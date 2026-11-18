fn main() {
  let cs = "aé🦆xyz".chars()
  let v = cs[1..5]
  print([str(cs), str(cs[0..3]), str(cs[1..=2]), str(cs[2..2]), str(v[1..3]), str(cs[3..cs.len()])])
  let r = catch str(cs[4..9])
  print("{r}".contains("slice 4..9 out of range for length 6"))
}
