def test_hidden_primes_upto():
    assert primes_upto(10) == [2, 3, 5, 7]
    assert primes_upto(-5) == []
    assert primes_upto(0) == []
    assert primes_upto(1) == []
    assert primes_upto(2) == [2]
    assert primes_upto(3) == [2, 3]
    assert primes_upto(30) == [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
    assert primes_upto(49)[-1] == 47
    big = primes_upto(10_000)
    assert len(big) == 1229
    assert big[-1] == 9973
    assert len(primes_upto(2_000_000)) == 148_933
