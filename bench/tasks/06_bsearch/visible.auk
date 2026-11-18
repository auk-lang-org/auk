test "visible bsearch" {
  assert bsearch([1, 3, 5, 7], 5) == some(2)
  assert bsearch([1, 3, 5, 7], 4) == none
}
