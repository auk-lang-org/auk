fn main(): ()! uses fs {
  let d = fs.temp_dir()?
  let p = "{d}/data.bin"
  let bs = (0..256).map(i => (i * 7 + 3) % 256)
  fs.write_bytes(p, bs)?
  let back = fs.read_bytes(p)?
  print("{back.len()} {back == bs} {back.take(3)}")
  print(fs.write_bytes(p, [1, 300]) else e => print("{e}"))
  print((fs.read_bytes(p)?).len())
  fs.write_bytes(p, "hé".bytes())?
  print(fs.read(p)?)
  fs.remove(p)?
  fs.remove(d)?
}
