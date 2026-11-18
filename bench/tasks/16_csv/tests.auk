test "hidden split_csv" {
  assert split_csv("a,b,c")? == ["a", "b", "c"]
  assert split_csv("")? == [""]
  assert split_csv("a,,c,")? == ["a", "", "c", ""]
  assert split_csv(",")? == ["", ""]
  assert split_csv("\"x,y\",z")? == ["x,y", "z"]
  assert split_csv("\"say \"\"hi\"\"\"")? == ["say \"hi\""]
  assert split_csv("\"\"")? == [""]
  assert split_csv("\"\",\"\"")? == ["", ""]
  assert split_csv("ab\"c,d")? == ["ab\"c", "d"]
  assert split_csv(" \"a\" , b ")? == [" \"a\" ", " b "]
  assert split_csv("x,\"multi, comma, field\"")? == ["x", "multi, comma, field"]
  assert split_csv("é,\"ü\"")? == ["é", "ü"]
}

test "hidden split_csv errors" {
  assert split_csv("\"abc") is err(Unterminated)
  assert split_csv("a,\"b\"\"") is err(Unterminated)
  assert split_csv("\"a\"b,c") is err(JunkAfterQuote(3))
  assert split_csv("x,\"a\" ,y") is err(JunkAfterQuote(5))
  assert split_csv("é,\"ü\"x") is err(JunkAfterQuote(5))
}
