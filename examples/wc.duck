/// Print the 10 most common words in a file.

fn main(args: [str]): int! uses fs {
  let [_, path] = args else {
    print("usage: wc <file>")
    return 2
  }
  let text = fs.read(path)?
  let top = text.lower().split().counts().entries().sort_by(e => -e.1).take(10)
  for i, (word, n) in top {
    print("{i + 1:>2}. {word:<15} {n}")
  }
  0
}
