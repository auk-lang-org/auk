enum Id { User(n: int) }
fn num(id: Id): int {
  let User(n) = id else { return 0 }
  n
}
