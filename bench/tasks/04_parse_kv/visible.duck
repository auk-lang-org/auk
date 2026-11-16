test "visible parse_kv" {
  assert parse_kv("a=1; b = -2;c=3;")? == {"a": 1, "b": -2, "c": 3}
  assert parse_kv("a=1;oops") is err(MissingEq(1))
}
