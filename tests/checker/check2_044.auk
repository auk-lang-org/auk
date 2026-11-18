fn load(p: str): str uses fs = fs.read(p) else ""
fn all(ps: [str]): [str] = ps.map(load)
fn main() {}
