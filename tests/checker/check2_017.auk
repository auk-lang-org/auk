fn len([]): int = 0
fn len([_, ..t]: [int]): int = 1 + len(t)
fn main() {}
