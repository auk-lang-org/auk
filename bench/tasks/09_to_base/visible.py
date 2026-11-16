def test_visible_to_base():
    assert to_base(255, 16) == "ff"
    assert to_base(-5, 2) == "-101"
    assert to_base(0, 10) == "0"
