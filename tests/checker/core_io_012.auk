fn names(d: str): [str]! = fs.list(d)
fn main() { print(names(".")) }
