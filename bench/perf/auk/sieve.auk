fn main(args: [str]) {
  let n = int.parse(args[1]) else 1000
  var sieve: [bool] = []
  for _ in 0..=n { sieve.push(true) }
  var count = 0
  for i in 2..=n {
    if sieve[i] {
      count += 1
      var j = i * i
      while j <= n {
        sieve[j] = false
        j += i
      }
    }
  }
  print(count)
}
