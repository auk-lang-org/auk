test "hidden rle_encode" {
  assert rle_encode("aaabccdddd") == "a3bc2d4"
  assert rle_encode("") == ""
  assert rle_encode("abc") == "abc"
  assert rle_encode("aaaaaaaaaaaa") == "a12"
  assert rle_encode("aabbaa") == "a2b2a2"
  assert rle_encode("  x") == " 2x"
}

test "hidden rle_decode" {
  assert rle_decode("a3bc2d4")? == "aaabccdddd"
  assert rle_decode("")? == ""
  assert rle_decode("abc")? == "abc"
  assert rle_decode("a12")? == "aaaaaaaaaaaa"
  assert rle_decode(" 2x")? == "  x"
  assert rle_decode("a1b1")? == "ab"
  assert rle_decode("3a") is err(LeadingDigit)
  assert rle_decode("a0") is err(ZeroCount)
  assert rle_decode("ab00") is err(ZeroCount)
  assert rle_decode(rle_encode("xxyzzzzzzzzzzzzzzq"))? == "xxyzzzzzzzzzzzzzzq"
}
