def test_hidden_to_roman():
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


def test_hidden_from_roman():
    assert from_roman("MCMXCIV") == 1994
    assert from_roman("I") == 1
    assert from_roman("MMMCMXCIX") == 3999
    assert from_roman("XLIX") == 49
    assert from_roman("") is None
    assert from_roman("IIII") is None
    assert from_roman("IC") is None
    assert from_roman("VX") is None
    assert from_roman("MMMM") is None
    assert from_roman("mcm") is None
    assert from_roman("X1") is None
    assert from_roman("XIIX") is None
    assert all(from_roman(to_roman(n)) == n for n in range(1, 4000))
