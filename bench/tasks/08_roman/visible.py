def test_visible_roman():
    assert to_roman(1994) == "MCMXCIV"
    assert from_roman("MCMXCIV") == 1994
    assert from_roman("IIII") is None
