/// The self-hosting port's driver: `compiler tokens|ast|resolve|check|typed [--quiet] [--time]
/// [--repeat N] [--core] [--all] <file>...` prints what `auk dump tokens|ast|resolve|check|typed`
/// prints, from the Auk port of the front end; `check [--json] <file>` and `holes [--json] <file>`
/// print what `auk check` and `auk holes` print, with the same exit code (`check` with several
/// files prints `auk dump check`'s report of the type checker alone); `typed` the typed program
/// (`--core`: core modules' tables too). For timing: `--quiet` does the work without printing
/// (`check --quiet` runs the type checker alone, with `--all` all of `auk check`), `--repeat N`
/// does the whole job N times, and `--time` prints the time per repetition (file reading
/// excluded) to stderr.
///
/// `resolve`, `check` and `typed` read the core prelude from `$AUK_PRELUDE_DIR`, or else from the
/// `src/prelude/` of the checkout the binary was built in (found upward from the binary).

let MODES = ["tokens", "ast", "resolve", "check", "typed", "holes"]

fn main(args: [str]): int! uses fs, env, time, ffi {
  if args.len() >= 2 && args[1] == "fmt" { return fmt.run(args.skip(2)) }
  if args.len() < 3 || !MODES.contains(args[1]) {
    eprint("usage: compiler tokens|ast|resolve|check|typed [--quiet] [--time] [--repeat N] [--core] <file>... | fmt [--check] <path>...")
    return 2
  }
  let what = args[1]
  let rest = args.skip(2)
  let quiet = rest.contains("--quiet")
  let time_it = rest.contains("--time")
  let core = rest.contains("--core")
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
  // `check [--json] <file>` and `holes [--json] <file>`: what `auk check`/`auk holes` print
  let cli_mode = (what == "check" || what == "holes") && !quiet && !time_it && !rest.contains("--repeat") && files.len() == 1
  if !cli_mode {
    for f in files { srcs.push(fs.read(f)?) }
  }
  var cx = resolve.Sources { prelude: [], overrides: {}, os: "" }
  var cwd = ""
  if what == "resolve" || what == "check" || what == "typed" || what == "holes" {
    let dir = prelude_dir(args[0]) else {
      eprint("error: can't find the core prelude (src/prelude/core.auk); set AUK_PRELUDE_DIR")
      return 1
    }
    cx = resolve.sources(dir)?
    cwd = paths.cwd()
  }
  if cli_mode {
    let json = rest.contains("--json")
    return if what == "check" { cli.check_file(cx, files[0], json) } else { holes.run(cx, files[0], json) }
  }
  let t0 = time.now()
  var out: [str] = []
  for _ in 0..repeat {
    for i, f in files {
      let src = srcs[i]
      if files.len() > 1 && !quiet { out.push("== {f}") }
      if what == "check" || what == "typed" {
        let r = resolve.load_in_package(cx, f, src)
        if quiet {
          match r {
            ok(p) => if rest.contains("--all") { let _ = check.check_all(p) } else { let _ = check.check_types(p) }
            err(_) => {}
          }
        } else if what == "check" {
          out.push(dump.checked(f, r))
        } else {
          dump.typed_program(&out, cwd, r, core)
        }
      } else if what == "resolve" {
        let r = resolve.load_in_package(cx, f, src)
        if !quiet { dump.resolved(&out, cwd, r) }
      } else if what == "tokens" {
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

/// `$AUK_PRELUDE_DIR`, or the first `src/prelude` with a `core.auk` above the binary `exe`.
fn prelude_dir(exe: str): str? uses fs, env, ffi {
  match env.get("AUK_PRELUDE_DIR") {
    some(d) => return d
    none => {}
  }
  var d = paths.parent(paths.canonicalize(exe) else exe)
  loop {
    let x = d else return none
    let p = paths.join(x, "src/prelude")
    if paths.is_file(paths.join(p, "core.auk")) { return p }
    d = paths.parent(x)
  }
}
