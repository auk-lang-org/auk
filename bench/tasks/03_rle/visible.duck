test "visible rle" {
  assert rle_encode("aaabccdddd") == "a3bc2d4"
  assert rle_decode("a3bc2d4")? == "aaabccdddd"
  assert rle_decode("3a") is err(LeadingDigit)
}
