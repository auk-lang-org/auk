test "hidden primes_upto" {
  assert primes_upto(10) == [2, 3, 5, 7]
  assert primes_upto(-5) == []
  assert primes_upto(0) == []
  assert primes_upto(1) == []
  assert primes_upto(2) == [2]
  assert primes_upto(3) == [2, 3]
  assert primes_upto(30) == [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
  assert primes_upto(49).last() == some(47)
  let big = primes_upto(10_000)
  assert big.len() == 1229
  assert big.last() == some(9973)
  assert primes_upto(2_000_000).len() == 148_933
}
