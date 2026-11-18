test "visible roman" {
  assert to_roman(1994) == "MCMXCIV"
  assert from_roman("MCMXCIV") == some(1994)
  assert from_roman("IIII") == none
}
