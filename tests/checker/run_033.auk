fn sign(0): int
  ensures result == 0
{ 0 }
fn sign(n: int): int when n > 0 { 5 }
fn sign(n: int): int
  ensures result == 1
{ -1 }
fn main() {
  print(sign(0))
  print(sign(5))
  print(sign(-5))
}
