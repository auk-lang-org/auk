// error: E0410 `load` uses the effect `fs` but doesn't declare it
fn load(path: str): str! = fs.read(path)

fn main() {
  print(load("notes.txt") else "")
}
