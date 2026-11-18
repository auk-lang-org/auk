enum Light { Red, Amber, Green }

fn go(l: Light, n: int): bool = match l {
  Red when n > 3 => true
  Amber => false
  Green when n > 0 => true
  Red => false
}

fn wait(Red, n: int): int when n > 1 = n
fn wait(Green, _: int): int = 0

fn grade(n: int): str = match n {
  _ => "x"
  k when k > 90 => "A"
  9 => "nine"
}

fn main() {
  print(go(Light.Red, 1))
  print(wait(Light.Green, 2))
  print(grade(1))
}
