extern fn a(): [int] = "#embed nope.bin"
extern fn b(): float = "#embed bad.txt"
extern fn c(x: int): int = "#embed bad.txt"
extern fn d(): str = "#embed bad.txt"
fn main() {}
