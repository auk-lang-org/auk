fn apply(n: var int, g: (var int) => ()) { g(&n) }
fn main() {
  var a = 1
  apply(&a, x => {
    let f = () => { x += 1 }
    f()
  })
}
