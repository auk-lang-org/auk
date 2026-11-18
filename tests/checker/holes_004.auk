fn main() {
  print(geo.scale([1, 2], 3))
}

test "scale" {
  assert geo.scale([1], 2) == [4]
}

test "other" {
  assert 1 + 1 == 2
}
