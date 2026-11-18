fn main(args: [str]) {
  let n = int.parse(args[1]) else 1000
  var parts: [str] = []
  for i in 0..n { parts.push("w{i % 1000}") }
  let text = parts.join(" ")
  var counts: {str: int} = {}
  for w in text.split(" ") {
    counts[w] = (counts.get(w) else 0) + 1
  }
  var total = 0
  for c in text.chars() { if c == 'w' { total += 1 } }
  print("{text.len()} {counts.len()} {total}")
}
