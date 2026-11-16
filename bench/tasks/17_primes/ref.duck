fn primes_upto(n: int): [int] {
  if n < 2 { return [] }
  var sieve: [bool] = []
  for _ in 0..=n { sieve.push(true) }
  var out: [int] = []
  for i in 2..=n {
    if sieve[i] {
      out.push(i)
      var j = i * i
      while j <= n {
        sieve[j] = false
        j += i
      }
    }
  }
  out
}
