test "visible split_csv" {
  assert split_csv("a,b,c")? == ["a", "b", "c"]
  assert split_csv("\"x,y\",z")? == ["x,y", "z"]
  assert split_csv("\"abc") is err(Unterminated)
}
