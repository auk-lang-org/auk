def test_visible_balanced():
    assert balanced("([]{})")
    assert not balanced("([)]")
