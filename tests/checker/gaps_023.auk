fn main() {
  print(int.parse("ff", 16))
  print(int.parse("-FF", 16))
  print(int.parse("1010_1010", 2))
  print(int.parse("zz", 36))
  print(int.parse("7fffffffffffffff", 16))
  print(int.parse("-8000000000000000", 16))
  print(int.parse("8000000000000000", 16))
  print(int.parse("12", 2))
  print(int.parse("", 16))
  print(int.parse("1", 37) else e => -1)
  print("{'f'.is_digit(16)} {'g'.is_digit(16)} {'7'.is_digit(8)} {'8'.is_digit(8)} {'Z'.is_digit(36)}")
}
