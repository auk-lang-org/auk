fn main(): int! {
  let u = url.parse("https://a.com/x?q=a+b")?
  print(u.param("q") else "")
  print(hash.sha256_hex("abc").len())
  print(encoding.base64("hi".bytes()))
  print("{datetime.from_unix_ms(0)}")
  let v = toml.parse("a = 1")?
  print(v == Map({"a": Int(1)}))
  log.new(log.Info).info("done")
  0
}
