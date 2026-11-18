/// Print the lines of stdin that contain a pattern, with their line numbers.
/// `auk run examples/grep.auk raft < notes.txt`; exits with 1 when nothing matches.

fn main(args: [str]): int uses env, proc {
  let [_, pattern] = args else {
    eprint("usage: grep <pattern>")
    proc.exit(2)
  }
  var n = 0
  var found = 0
  loop {
    let line = env.read_line() else { break }
    n += 1
    if line.contains(pattern) {
      print("{n}: {line}")
      found += 1
    }
  }
  if found > 0 { 0 } else { 1 }
}
