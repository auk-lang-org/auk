test "hidden to_roman" {
  assert to_roman(1) == "I"
  assert to_roman(4) == "IV"
  assert to_roman(9) == "IX"
  assert to_roman(14) == "XIV"
  assert to_roman(40) == "XL"
  assert to_roman(58) == "LVIII"
  assert to_roman(90) == "XC"
  assert to_roman(400) == "CD"
  assert to_roman(944) == "CMXLIV"
  assert to_roman(1994) == "MCMXCIV"
  assert to_roman(2024) == "MMXXIV"
  assert to_roman(3999) == "MMMCMXCIX"
}

test "hidden from_roman" {
  assert from_roman("MCMXCIV") == some(1994)
  assert from_roman("I") == some(1)
  assert from_roman("MMMCMXCIX") == some(3999)
  assert from_roman("XLIX") == some(49)
  assert from_roman("") == none
  assert from_roman("IIII") == none
  assert from_roman("IC") == none
  assert from_roman("VX") == none
  assert from_roman("MMMM") == none
  assert from_roman("mcm") == none
  assert from_roman("X1") == none
  assert from_roman("XIIX") == none
  assert (1..=3999).all(n => from_roman(to_roman(n)) == some(n))
}
