test "hidden bsearch" {
  assert bsearch([1, 3, 5, 7], 5) == some(2)
  assert bsearch([1, 3, 5, 7], 4) == none
  assert bsearch([], 1) == none
  assert bsearch([1, 3, 5, 7], 1) == some(0)
  assert bsearch([1, 3, 5, 7], 7) == some(3)
  assert bsearch([1, 3, 5, 7], 0) == none
  assert bsearch([1, 3, 5, 7], 8) == none
  assert bsearch([2, 2, 2, 3], 2) == some(0)
  assert bsearch([1, 2, 2, 2], 2) == some(1)
  assert bsearch([5], 5) == some(0)
  assert bsearch([-10, -3, 0, 0, 9], 0) == some(2)
  let big = (0..1000).map(i => i * 2)
  assert bsearch(big, 1998) == some(999)
  assert bsearch(big, 777) == none
}
