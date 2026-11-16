test "hidden parse_kv ok" {
  assert parse_kv("a=1; b = -2;c=3;")? == {"a": 1, "b": -2, "c": 3}
  assert parse_kv("")? == {}
  assert parse_kv(" ; ;")? == {}
  assert parse_kv("a=1;b=2;a=5")? == {"a": 5, "b": 2}
  assert (parse_kv("a=1;b=2;a=5")?).keys() == ["a", "b"]
  assert parse_kv("  long key  =  42  ")? == {"long key": 42}
}

test "hidden parse_kv errors" {
  assert parse_kv("a=1;oops") is err(MissingEq(1))
  assert parse_kv(";;x") is err(MissingEq(2))
  assert parse_kv("a=1;;=3") is err(EmptyKey(2))
  assert parse_kv("  =3") is err(EmptyKey(0))
  assert parse_kv("x=1.5") is err(BadValue("x"))
  assert parse_kv("k=1=2") is err(BadValue("k"))
  assert parse_kv("k=") is err(BadValue("k"))
  assert parse_kv("k=x;oops") is err(BadValue("k"))
  assert parse_kv("oops;k=x") is err(MissingEq(0))
}
