enum ReadErr { Missing }
enum AppErr { Bad }
fn read(): int!ReadErr = 1
fn run(): int!AppErr {
  let x = read() else e => fail(Bad)
  x
}
