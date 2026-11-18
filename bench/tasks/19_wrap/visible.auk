test "visible wrap" {
  assert wrap("the quick brown fox", 10) == ["the quick", "brown fox"]
  assert wrap("", 5) == []
}
