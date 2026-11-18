fn main(): ()! uses fs {
  let d = fs.temp_dir()?
  assert fs.is_dir(d) && (fs.list(d)?).len() == 0
  fs.mkdir("{d}/x/y/z")?
  fs.mkdir("{d}/x/y")?
  fs.write("{d}/b.txt", "one\n")?
  fs.append("{d}/b.txt", "two\n")?
  fs.append("{d}/a.txt", "new")?
  print(fs.list(d)?)
  print(fs.lines("{d}/b.txt")?)
  fs.rename("{d}/a.txt", "{d}/x/c.txt")?
  print("{fs.exists("{d}/a.txt")} {fs.exists("{d}/x/c.txt")} {fs.is_dir("{d}/x/c.txt")}")
  print(fs.remove("{d}/x") is err(_))
  print(fs.list("{d}/nope") is err(_))
  fs.remove("{d}/x/c.txt")?
  fs.remove("{d}/x/y/z")?
  fs.remove("{d}/x/y")?
  fs.remove("{d}/x")?
  fs.remove("{d}/b.txt")?
  fs.remove(d)?
  print(fs.exists(d))
}
