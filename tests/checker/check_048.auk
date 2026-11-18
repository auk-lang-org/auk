struct A { a: int }
struct B { b: int }
fn show(x: A): str = "a"
fn show(x: B): str = "b"
fn main() { print(show(A { a: 1 }) + B { b: 2 }.show()) }
