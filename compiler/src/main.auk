/// The self-hosting pilot's driver: `compiler tokens|ast [--quiet] [--time] <file>...` prints
/// what `auk dump tokens|ast` prints, from the Auk port of the lexer and parser.

fn main(args: [str]): int! uses fs, time {
  if args.len() < 3 || (args[1] != "tokens" && args[1] != "ast") {
    eprint("usage: compiler tokens|ast [--quiet] [--time] <file>...")
    return 2
  }
  let what = args[1]
  let rest = args.skip(2)
  let quiet = rest.contains("--quiet")
  let time_it = rest.contains("--time")
  let files = rest.filter(a => !a.starts_with("--"))
  var srcs: [str] = []
  for f in files { srcs.push(fs.read(f)?) }
  let t0 = time.now()
  var out: [str] = []
  for i, f in files {
    let src = srcs[i]
    if files.len() > 1 && !quiet { out.push("== {f}") }
    if what == "tokens" {
      match lexer.lex(src) {
        ok(lx) => if !quiet { dump.tokens(&out, lx.module_doc, lx.toks) }
        err(Bad(d)) => if !quiet { dump.diag_dump(&out, d) }
      }
    } else {
      eprint("ast: not yet")
    }
  }
  if out.len() > 0 { print(out.join("\n")) }
  if time_it { eprint("time: {(time.now() - t0) * 1000} us") }
  0
}
