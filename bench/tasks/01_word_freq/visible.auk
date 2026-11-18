test "visible word_freq" {
  assert word_freq("the cat saw the dog") == {"the": 2, "cat": 1, "saw": 1, "dog": 1}
}
