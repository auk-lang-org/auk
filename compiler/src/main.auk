/// The self-hosting pilot's driver: `compiler tokens|ast [--quiet] [--time] [--repeat N]
/// <file>...` prints what `auk dump tokens|ast` prints, from the Auk port of the lexer and
/// parser. For timing: `--quiet` lexes or parses without printing, `--repeat N` does the whole
/// job N times, and `--time` prints the time per repetition (file reading excluded) to stderr.

fn main(args: [str]): int! uses fs, time {
  if args.len() < 3 || (args[1] != "tokens" && args[1] != "ast") {
    eprint("usage: compiler tokens|ast [--quiet] [--time] [--repeat N] <file>...")
    return 2
  }
  let what = args[1]
  let rest = args.skip(2)
  let quiet = rest.contains("--quiet")
  let time_it = rest.contains("--time")
  var repeat = 1
  var files: [str] = []
  for i, a in rest {
    if a == "--repeat" {
      repeat = int.parse(rest.get(i + 1) else "1") else 1
    } else if !a.starts_with("--") && (i == 0 || rest[i - 1] != "--repeat") {
      files.push(a)
    }
  }
  var srcs: [str] = []
  for f in files { srcs.push(fs.read(f)?) }
  let t0 = time.now()
  var out: [str] = []
  for _ in 0..repeat {
    for i, f in files {
      let src = srcs[i]
      if files.len() > 1 && !quiet { out.push("== {f}") }
      if what == "tokens" {
        match lexer.lex(src) {
          ok(lx) => if !quiet { dump.tokens(&out, lx.module_doc, lx.toks) }
          err(Bad(d)) => if !quiet { dump.diag_dump(&out, d) }
        }
      } else {
        let parts = f.split("/")
        let prelude = parts.len() >= 2 && parts[parts.len() - 2] == "prelude"
        match parser.parse(src, prelude) {
          ok(m) => if !quiet { dump.module(&out, m) }
          err(Many(ds)) => if !quiet {
            for d in ds { dump.diag_dump(&out, d) }
          }
        }
      }
    }
  }
  if out.len() > 0 { print(out.join("\n")) }
  if time_it { eprint("time: {(time.now() - t0) * 1000 / repeat} us") }
  0
}
