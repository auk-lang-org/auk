enum Id { User(n: int) }
fn num(id: Id): int {
  let User(n) = id
  n
}
