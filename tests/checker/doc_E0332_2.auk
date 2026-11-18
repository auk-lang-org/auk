async fn ping(): int = 1
fn main() {
  let n = await ping()
  print(n)
}
