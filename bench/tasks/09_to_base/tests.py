def test_hidden_to_base():
    assert to_base(255, 16) == "ff"
    assert to_base(-5, 2) == "-101"
    assert to_base(0, 10) == "0"
    assert to_base(0, 2) == "0"
    assert to_base(-255, 16) == "-ff"
    assert to_base(35, 36) == "z"
    assert to_base(36, 36) == "10"
    assert to_base(-1, 2) == "-1"
    assert to_base(1_000_000, 10) == "1000000"
    assert to_base(8, 8) == "10"
    assert to_base(9223372036854775807, 36) == "1y2p0ij32e8e7"
    assert to_base(9223372036854775807, 2) == "1" * 63
    assert to_base(-9223372036854775807 - 1, 2) == "-1" + "0" * 63
    assert to_base(-9223372036854775807 - 1, 10) == "-9223372036854775808"
    assert to_base(-9223372036854775807 - 1, 16) == "-8000000000000000"
