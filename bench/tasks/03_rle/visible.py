def test_visible_rle():
    assert rle_encode("aaabccdddd") == "a3bc2d4"
    assert rle_decode("a3bc2d4") == "aaabccdddd"
    assert isinstance(catch(lambda: rle_decode("3a")), LeadingDigit)
