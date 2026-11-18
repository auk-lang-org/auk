fn to_base(n: int, base: int): str
  requires base >= 2 && base <= 36
{
  if n == 0 { return "0" }
  let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  var cs: [char] = []
  var m = n
  // work with non-positive values so the minimum int doesn't overflow
  if m > 0 { m = -m }
  while m != 0 {
    cs.push(digits[-(m % base)])
    m = m / base
  }
  let s = str(cs.reverse())
  if n < 0 { "-" + s } else { s }
}
