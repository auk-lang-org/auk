def test_visible_is_valid_date():
    assert is_valid_date("2024-02-29")
    assert not is_valid_date("2023-02-29")
    assert not is_valid_date("2023-13-01")
