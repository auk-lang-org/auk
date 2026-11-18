fn kind(v: Value): str = match v {
  Null => "null"
  Map({"a": Int(n), "b": Str(s)}) => s
  Map({"a": Int(n)}) => "a"
  List([]) => "empty"
  List([Int(_), ..]) => "ints"
}

fn keys({"x": a, "y": b}: {str: int}): int = a + b
fn keys({"y": b, "x": a}: {str: int}): int = 0

fn main() {
  print(kind(Value.Null))
  print(keys({}))
}
