fn len([], acc: int): int = acc
fn len([_, _, ..t]: [int], acc: int): int = len(t, acc + 2)
fn main() {}
